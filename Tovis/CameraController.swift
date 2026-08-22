// A minimal custom camera over AVFoundation: live preview + still capture → JPEG.
//
// Built custom (not the system PhotosPicker) on purpose: the "AI photographer"
// taps the live frame buffer (AVCaptureVideoDataOutput) for the on-device coach
// (lighting / composition / background / pose) and draws overlays on the preview.
// Capture, recording, and the live coaching hook all ship here today — the coach
// itself lives in CoachEngine.
import AVFoundation
import OSLog
import SwiftUI
import TovisKit

enum CameraError: Error { case noData, captureInProgress, timedOut }

/// A non-Sendable value being handed across an isolation boundary on purpose.
///
/// This exists so such a transfer has to be WRITTEN DOWN. `@preconcurrency
/// import AVFoundation` would silence the whole module's Sendable diagnostics
/// in one line — including the ones worth reading — whereas every use of this
/// box is a single, greppable place where someone claimed an invariant the
/// compiler cannot check, and had to say what it was.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

@Observable
@MainActor
final class CameraController: NSObject {
    enum Status: Equatable { case idle, configuring, ready, interrupted, denied, failed(String) }

    private(set) var status: Status = .idle

    // ═══════════════════════════════════════════════════════════════════════
    // THE ISOLATION STORY. There are exactly two homes for state in this
    // class, and every property below says which one it lives in.
    //
    //   • MAIN ACTOR — everything the SwiftUI view observes (`status`,
    //     `aeAfLocked`, `whiteBalanceCalibrated`, `isRecording`, the callbacks,
    //     `previewLayer`). Declared plainly, with no isolation attribute.
    //
    //   • `sessionQueue` — every AVFoundation object, the active `device`, and
    //     the bookkeeping the queue closures read. Declared `nonisolated`, and
    //     **never touched from the main actor**. Where the main actor genuinely
    //     needs one of these, it hops the queue explicitly via `onSessionQueue`.
    //
    // The rule that matters: `device` is read INSIDE `sessionQueue.async`, never
    // captured into it from the main actor. Build 38 died to a device parameter
    // that was validated at one instant and written at another, so this file
    // does not get to be casual about which thread is looking at the device —
    // and a `guard let device` on the main actor feeding a queue closure is
    // exactly that casualness, plus a genuine unsynchronized read of a property
    // `configureSession` writes on the queue.
    // ═══════════════════════════════════════════════════════════════════════

    /// sessionQueue. `session` is also read by `CameraPreview` when it attaches
    /// the layer — an `AVCaptureSession` reference is safe to hand over; what is
    /// not safe is configuring it from two places, which is why every mutation
    /// below goes through the queue.
    nonisolated let session = AVCaptureSession()
    /// sessionQueue.
    nonisolated private let photoOutput = AVCapturePhotoOutput()
    /// sessionQueue.
    nonisolated private let videoOutput = AVCaptureVideoDataOutput()
    /// The active capture device — kept so tap-to-focus / AE-AF lock can configure
    /// its focus + exposure. **sessionQueue only.** Written by `configureSession`
    /// on that queue; reading it from the main actor would be an unsynchronized
    /// read of a property another thread writes.
    @ObservationIgnored nonisolated(unsafe) private var device: AVCaptureDevice?
    /// The live preview layer, for converting tap points to device coordinates.
    /// **Main actor only** — it is created by `CameraPreview.makeUIView` on the
    /// main thread and every read (`focus(atLayerPoint:)`, the framing overlay)
    /// is a main-thread UIKit read. It was never session-queue state.
    @ObservationIgnored weak var previewLayer: AVCaptureVideoPreviewLayer?
    /// Whether focus + exposure are currently locked (AE/AF lock).
    private(set) var aeAfLocked = false
    /// Whether white balance is locked to a calibrated (gray-card) value.
    private(set) var whiteBalanceCalibrated = false
    /// Fired (on the main actor) with the final locked WB gains — the camera
    /// view persists them per booking so before + after share one calibration.
    var onWhiteBalanceLocked: ((Double, Double, Double) -> Void)?
    /// Fired (on the main actor) when previously-persisted WB gains turn out to
    /// be unusable — the camera view drops the stored calibration rather than
    /// re-applying poison on every launch. See `applyWhiteBalanceGains`.
    var onWhiteBalanceUnusable: (() -> Void)?
    /// Records silent video clips (NO mic input — we never capture salon audio).
    /// sessionQueue.
    nonisolated private let movieOutput = AVCaptureMovieFileOutput()
    /// sessionQueue — the single source of truth for "inputs and outputs are
    /// attached". `start()` asks the queue for it rather than keeping a main-actor
    /// mirror, so there is one answer and it is never read while being written.
    @ObservationIgnored nonisolated(unsafe) private var configured = false
    /// sessionQueue.
    @ObservationIgnored nonisolated(unsafe) private var captureContinuation: CheckedContinuation<Data, Error>?
    /// Bumped per capture so a stale watchdog for a finished shot can't resolve a
    /// newer capture that has since reused the continuation slot. sessionQueue.
    @ObservationIgnored nonisolated(unsafe) private var captureToken = 0
    /// Longest we wait on a still's delegate callback before failing the awaiting
    /// continuation, so a capture the system silently drops can't strand the
    /// shutter (and leave `uploading` gating the whole UI shut) forever.
    /// Read from the session queue's watchdog, so `nonisolated`.
    nonisolated private static let captureWatchdog: TimeInterval = 10
    /// Longest single clip. A product number, not a measurement: a salon clip
    /// that earns its place is a few seconds of movement, and everything
    /// downstream (colour re-export, temp file, upload) scales with length.
    /// The clip's RESOLUTION, frame rate and codec are still inherited from the
    /// `.photo` preset and are deliberately left alone until the device pass
    /// measures what they actually are (`docs/design/camera-excellence-plan.md`
    /// §3.6) — changing the codec blind would risk web playback.
    nonisolated static let maxClipSeconds: Double = 60
    /// sessionQueue.
    @ObservationIgnored nonisolated(unsafe) private var recordContinuation: CheckedContinuation<URL, Error>?
    /// Bumped per stop so a stale watchdog can't resolve a later take that has
    /// since reused the continuation slot (same pattern as `captureToken`).
    /// sessionQueue.
    @ObservationIgnored nonisolated(unsafe) private var recordToken = 0
    /// Longest we wait on the recording delegate's finish callback before
    /// failing the awaiting continuation — a callback the system silently drops
    /// must not strand "Saving clip…" forever. Mirrors `captureWatchdog`.
    nonisolated private static let recordWatchdog: TimeInterval = 10
    /// Fired (on the main actor) when a recording finishes successfully with NO
    /// caller awaiting `stopRecording()` — the DOMINANT capped-take case:
    /// `maxRecordedDuration` fires while the pro is still shooting, so nobody
    /// ever calls stop, the continuation slot is empty, and without this hook
    /// the complete 60-second file sat orphaned in tmp. The view hands it to
    /// the ClipVault + upload queue, exactly like an awaited stop. (A late
    /// delegate arriving after the watchdog also lands here — its awaiter is
    /// gone, but the file is real.)
    var onUnawaitedClipFinished: ((URL) -> Void)?
    /// Whether the session could add the movie output (false → recording hidden).
    private(set) var recordingAvailable = false
    private(set) var isRecording = false
    /// Whether the active device has a torch (false → torch control hidden).
    /// Known only after `configureSession` has picked a device.
    private(set) var torchAvailable = false
    /// DEBUG only: the device-space point `setFaceExposure` last computed for
    /// the suspect (y, 1−x) transform — what the verification crosshair draws,
    /// converted back to layer space by the view. Main-actor written from the
    /// session queue via Task; debug diagnostics only, never read for control.
    ///
    /// Coupling note: `@ObservationIgnored`, so the crosshair overlay does not
    /// register a dependency on it. The overlay refreshes because SIBLING coach
    /// state (statuses, readiness) invalidates the view body every analysis
    /// frame (~6fps), re-reading this as a side effect. Reliable at today's
    /// cadence; if the camera ever stops re-rendering per frame, give this an
    /// observed home instead.
    #if DEBUG
    @ObservationIgnored private(set) var lastFaceMeterDevicePoint: CGPoint?
    #endif
    /// Live-frame delegate for the on-device coach. **sessionQueue only** — it is
    /// handed to `configureSession` as an argument rather than parked on the main
    /// actor and read from the queue, which is what it used to be. Weak: the
    /// CoachEngine owns it.
    @ObservationIgnored nonisolated(unsafe) private weak var frameDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?
    /// Notification tokens (subject-area change + session interruption), removed
    /// on deinit. sessionQueue (+ deinit).
    @ObservationIgnored nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []
    private let sessionQueue = DispatchQueue(label: "tovis.camera.session")
    private let frameQueue = DispatchQueue(label: "tovis.camera.frames")

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Read (or do) something on the session queue from the main actor, and wait
    /// for the answer.
    ///
    /// The point is that every main-actor → session-queue crossing in this file
    /// is spelled out at the call site. State that lives on the queue is never
    /// read directly from the main actor "because it's just a Bool" — that is
    /// how `device` and `configured` came to be written on one thread and read
    /// on another.
    private func onSessionQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            sessionQueue.async { cont.resume(returning: body()) }
        }
    }

    /// Make every caught AVFoundation exception visible.
    ///
    /// The shield turns a process kill into a degraded setting, which is the
    /// point — but a degradation nobody can see is a bug that never gets fixed.
    /// Three rounds of this crash were diagnosed from a backtrace that carried
    /// no exception `reason`; from here on the reason is in the log the first
    /// time it happens, next to the name of the write that raised.
    nonisolated private static func installExceptionLogging() {
        CaptureExceptionShield.onCaughtException = { label, outcome in
            Self.cameraLog.warning("⚠️ AVFoundation raised on `\(label, privacy: .public)` — write skipped, camera still running. \(outcome.reason ?? "no reason given", privacy: .public)")
        }
    }

    /// The one camera log. Replaces the `print()` calls this file used for
    /// caught exceptions and WB fallbacks — those compiled away in release
    /// builds, so a degradation the shield deliberately survives was invisible
    /// exactly where it happened. os_log carries these into Console + sysdiagnose
    /// on-device; `privacy: .public` is safe here because the payloads are
    /// AVFoundation exception reasons, never user content.
    nonisolated private static let cameraLog = Logger(subsystem: "app.tovis", category: "camera")

    /// Whether the SCREEN wants the session running. `stop()` clears it,
    /// `start()`/`resume()` set it. The interruption-ended observer consults
    /// this before restarting, so a queued `interruptionEnded` can't resurrect
    /// a session the screen deliberately paused (`stop()` behind the review
    /// sheet) — which would keep scoring + auto-harvesting while hidden.
    ///
    /// sessionQueue-confined like every other cross-home flag in this file:
    /// writers hop the queue to set it, the observer reads it inside its own
    /// `sessionQueue.async`. A plain unsynchronized Bool here is exactly the
    /// pattern the isolation preamble names as the origin of the
    /// `device`/`configured` bugs.
    @ObservationIgnored nonisolated(unsafe) private var isScreenActive = false

    /// Request permission, configure once, and start the preview. Idempotent.
    /// Pass `frameDelegate` to feed the on-device coach the live frames.
    func start(frameDelegate: AVCaptureVideoDataOutputSampleBufferDelegate? = nil) async {
        Self.installExceptionLogging()
        guard await Self.ensureAuthorized() else { status = .denied; return }
        sessionQueue.async { self.isScreenActive = true }

        // `configured` lives on the session queue, so ASK the queue rather than
        // reading it from here. The read used to race `configureSession`'s write
        // of the same property on that queue.
        let alreadyConfigured = await onSessionQueue { self.configured }
        if !alreadyConfigured {
            status = .configuring
            if let failure = await configureSession(frameDelegate: frameDelegate) {
                status = .failed(failure)
                return
            }
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if !self.session.isRunning {
                    CaptureExceptionShield.perform("startRunning") { self.session.startRunning() }
                }
                cont.resume()
            }
        }
        status = .ready
    }

    func stop() {
        sessionQueue.async {
            self.isScreenActive = false
            if self.session.isRunning {
                CaptureExceptionShield.perform("stopRunning") { self.session.stopRunning() }
            }
        }
    }

    /// Resume a session that was paused with `stop()` — without re-running auth /
    /// reconfiguration. Used when the pro returns from reviewing captured shots so
    /// the camera only runs while they're actually shooting (not behind a sheet,
    /// where it would keep scoring + auto-harvesting). No-op until configured.
    func resume() {
        sessionQueue.async {
            self.isScreenActive = true
            guard self.configured, !self.session.isRunning else { return }
            CaptureExceptionShield.perform("startRunning(resume)") { self.session.startRunning() }
        }
    }

    // MARK: - Torch

    /// The torch is a shooting tool in windowless salons, not a UI gimmick: it
    /// lights the WORK while the coach meters for it. Toggling it changes the
    /// room's light, so the card calibration's drift detector will (correctly)
    /// see the shift and offer a re-scan if it matters.
    func setTorch(_ on: Bool) {
        sessionQueue.async {
            guard let device = self.device, device.hasTorch,
                  (try? device.lockForConfiguration()) != nil else { return }
            CaptureExceptionShield.settings("torchMode") {
                device.torchMode = on ? .on : .off
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: - Zoom

    /// Zoom anchor captured when a pinch begins. sessionQueue-confined.
    @ObservationIgnored nonisolated(unsafe) private var pinchStartZoom: CGFloat = 1

    /// Anchor a new pinch: remember the zoom the gesture starts from, so the
    /// gesture's CUMULATIVE magnification can be applied relatively.
    /// Called (from the view) before the first `setPinchZoom` of a gesture;
    /// both hop the same queue, so FIFO ordering makes the anchor win.
    func beginPinchZoom() {
        sessionQueue.async {
            guard let device = self.device else { return }
            self.pinchStartZoom = device.videoZoomFactor
        }
    }

    /// Apply one pinch update: `magnification` is the gesture's cumulative
    /// scale since it began, multiplied against the anchored start zoom and
    /// clamped to the device's range. Redundant writes (sub-0.01 deltas, the
    /// queue draining faster than the gesture reports) are skipped so the
    /// lock/write cycle doesn't run at full gesture frequency for no change.
    ///
    /// The zoom FLOOR is the wide-angle parking factor, not 1.0: below it sits
    /// the ultra-wide constituent, and a stray pinch-out must not silently
    /// reframe every shot to 0.5× — the exact regression #268's parking guard
    /// exists to prevent. (The floor is per-DEVICE, so it is read here inside
    /// the queue where the parking zoom was applied.)
    func setPinchZoom(_ magnification: CGFloat) {
        guard magnification.isFinite, magnification > 0 else { return }
        sessionQueue.async {
            guard let device = self.device else { return }
            let desired = self.pinchStartZoom * magnification
            let floor = Self.wideAngleParkingFactor(device: device) ?? device.minAvailableVideoZoomFactor
            guard let safe = DeviceParameterGuard.clamped(
                desired,
                lower: floor,
                upper: device.maxAvailableVideoZoomFactor) else { return }
            // Crossing a constituent switch-over is handled BY the virtual
            // device itself — no manual lens management here, by design (#268).
            guard abs(device.videoZoomFactor - safe) > 0.01 else { return }
            guard (try? device.lockForConfiguration()) != nil else { return }
            CaptureExceptionShield.settings("pinch videoZoomFactor") {
                device.videoZoomFactor = safe
            }
            device.unlockForConfiguration()
        }
    }

    /// The zoom factor that parks a virtual device on its WIDE-ANGLE
    /// constituent (see `wideAngleZoomFactor`), or nil when there is no
    /// virtual-device parking to respect — a single wide camera has no
    /// constituents, so nothing to look up.
    ///
    /// The ONE lookup both call sites share: `matchWideAngleFraming` (park the
    /// framing at startup) and the pinch-zoom floor (never pinch into
    /// ultra-wide). House rule: no duplicate logic — the tested core is
    /// `wideAngleZoomFactor`; this wrapper is its device-facing face.
    nonisolated private static func wideAngleParkingFactor(device: AVCaptureDevice) -> CGFloat? {
        let constituents = device.constituentDevices
        guard !constituents.isEmpty,
              let wideIndex = constituents.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera })
        else { return nil }
        let factor = wideAngleZoomFactor(
            wideIndex: wideIndex,
            switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) })
        return factor > 1.0 ? factor : nil
    }

    /// Capture a still → JPEG `Data`.
    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            // `[self]` is explicit, and strong on purpose: this block owns the
            // continuation, so the controller has to outlive it or the caller
            // awaits forever. The watchdog nested below is deliberately `[weak
            // self]` instead — it fires seconds after this block has returned,
            // long past the lifetime this capture covers. Spelling the outer
            // capture out is what tells the compiler (and the next reader) the
            // two differ by intent rather than by accident.
            sessionQueue.async { [self] in
                // One capture at a time — a second call would overwrite the
                // stored continuation and strand the first caller forever.
                guard self.captureContinuation == nil else {
                    cont.resume(throwing: CameraError.captureInProgress)
                    return
                }
                self.captureContinuation = cont
                self.captureToken &+= 1
                let token = self.captureToken
                // Force JPEG so the bytes match the "image/jpeg" content-type we
                // presign with (the device default can be HEIC).
                let settings: AVCapturePhotoSettings
                if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                // Quality-prioritized processing, capped at 24 MP (the native
                // camera's own default on 48 MP sensors). Full-sensor stills
                // double every downstream decode/render (QC, card correction,
                // strip thumbnails) and the upload — transients that piled into
                // the jetsam kills — with no visible gain on the feed/profile.
                settings.photoQualityPrioritization = .quality
                // Match the output's declared ceiling exactly (set once in
                // `configureSession`). AVFoundation requires
                // `settings.maxPhotoDimensions ≤ photoOutput.maxPhotoDimensions`
                // or `capturePhoto` throws NSInvalidArgumentException.
                let outputMax = self.photoOutput.maxPhotoDimensions
                if outputMax.width > 0, outputMax.height > 0 {
                    CaptureExceptionShield.settings("settings.maxPhotoDimensions") {
                        settings.maxPhotoDimensions = outputMax
                    }
                }
                // A raise here means no delegate callback ever arrives, so the
                // awaiting continuation must be failed rather than left to the
                // 10s watchdog with the shutter gated shut.
                if CaptureExceptionShield.perform("capturePhoto", {
                    self.photoOutput.capturePhoto(with: settings, delegate: self)
                }).didThrow {
                    self.resolveCapture(.failure(CameraError.noData))
                    return
                }
                // Watchdog: if neither capture delegate fires (a shot the system
                // silently drops — session interrupted mid-capture, an output
                // glitch), fail this capture after a beat so the caller recovers.
                // Gated on the token so it can't clobber a later capture that has
                // since reused the slot.
                //
                // The weak capture is bound to `controller` rather than
                // re-binding `self`: the enclosing block holds `self` STRONGLY
                // (deliberate — see the comment on `capturePhoto`'s outer
                // closure), and re-binding the same name with different
                // ownership makes the compiler flag the contrast as an error-
                // looking mismatch. Same intent, spelled without the warning.
                self.sessionQueue.asyncAfter(deadline: .now() + Self.captureWatchdog) { [weak self] in
                    guard let controller = self, controller.captureToken == token else { return }
                    controller.resolveCapture(.failure(CameraError.timedOut))
                }
            }
        }
    }

    /// Resolve the pending photo continuation exactly once — whichever of the
    /// capture delegate or the watchdog reaches it first wins; the other no-ops
    /// because the continuation is already cleared. sessionQueue-confined.
    nonisolated private func resolveCapture(_ result: Result<Data, Error>) {
        guard let cont = self.captureContinuation else { return }
        self.captureContinuation = nil
        switch result {
        case let .success(data): cont.resume(returning: data)
        case let .failure(error): cont.resume(throwing: error)
        }
    }

    // MARK: - Focus & exposure

    /// Tap-to-focus + meter at a point in the preview layer's coordinate space.
    /// Sets a one-shot auto-focus/expose there and releases any AE/AF lock. The
    /// subject-area-change observer (registered in `configureSession`) restores
    /// continuous AF/AE once the scene moves on, so a tap doesn't pin focus for
    /// the rest of the shoot.
    func focus(atLayerPoint layerPoint: CGPoint) {
        // The layer conversion is main-actor work (it reads UIKit geometry), so
        // it happens here; the DEVICE is read on the queue that owns it.
        guard let layer = previewLayer else { return }
        // A preview layer that hasn't been laid out yet has zero bounds, and the
        // conversion then divides by it — a NaN point of interest is an ObjC
        // exception on the write, not a missed tap.
        guard let point = DeviceParameterGuard.unitPoint(
            layer.captureDevicePointConverted(fromLayerPoint: layerPoint)) else { return }
        sessionQueue.async {
            guard let device = self.device,
                  (try? device.lockForConfiguration()) != nil else { return }
            // Unlock is AFTER the shielded block, never a `defer` inside it —
            // an ObjC unwind runs no Swift cleanup. See CaptureDeviceShielding.
            CaptureExceptionShield.settings("focus(atLayerPoint:)") {
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
            }
            device.unlockForConfiguration()
            self.userMeteringActive = true   // face metering stands down
            #if DEBUG
            // The crosshair must not outlive face metering. Published HERE —
            // at the transition, inside the queue that owns `userMeteringActive`
            // — because setFaceExposure's guard returns early while this is set,
            // so its publish site never runs to clear it.
            Task { @MainActor in self.lastFaceMeterDevicePoint = nil }
            #endif
            Task { @MainActor in self.aeAfLocked = false }
        }
    }

    /// Scene changed after a tap-to-focus — hand focus/exposure back to the
    /// continuous system so the camera tracks the shoot again. Runs on
    /// `sessionQueue`. (An engaged AE/AF lock turns monitoring off, so this
    /// never fights the lock.)
    nonisolated private func restoreContinuousFocus() {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        CaptureExceptionShield.settings("restoreContinuousFocus") {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.isSubjectAreaChangeMonitoringEnabled = false
        }
        device.unlockForConfiguration()
        userMeteringActive = false
    }

    // MARK: - Face-priority exposure

    /// A user tap-to-focus meter is in play (until the scene moves on) — face
    /// metering stands down so it doesn't fight the pro's explicit intent.
    /// sessionQueue-confined.
    @ObservationIgnored nonisolated(unsafe) private var userMeteringActive = false
    /// Last face point we metered at (device space), to rate-limit updates.
    @ObservationIgnored nonisolated(unsafe) private var lastFaceExposurePoint: CGPoint?
    /// Whether a face is currently driving the meter (the no-face fallback
    /// point is dead center, so the point alone can't tell). sessionQueue-confined.
    @ObservationIgnored nonisolated(unsafe) private var faceMeteringActive = false
    /// Card-anchored exposure: EV bias from the calibration card's neutral band
    /// ("this gray must render at reference luma in THIS room's light").
    /// Composes with the face-metering highlight bias. sessionQueue-confined.
    @ObservationIgnored nonisolated(unsafe) private var calibrationBiasEV: Float = 0

    /// Continuously meter exposure for the subject's face — what a photographer
    /// does by default, and what silently fixes "too dark" / "backlit" instead
    /// of asking the pro to. `center` is the face center in upright,
    /// top-left-normalized frame coords (nil = no face → back to center-weighted).
    /// Stands down while AE/AF is locked or a tap-to-focus meter is active.
    /// Fed by the coach's per-frame face detection (already running).
    func setFaceExposure(center: CGPoint?) {
        sessionQueue.async {
            guard let device = self.device,
                  !self.userMeteringActive,
                  device.exposureMode != .locked,
                  device.isExposurePointOfInterestSupported else { return }
            // Upright top-left (x, y) → device space (sensor landscape-right,
            // top-left origin): (y, 1 − x). ⚠️ Verify on hardware, like the
            // level sign — sensor mounting can flip this. The DEBUG crosshair
            // draws exactly THIS point, converted back to layer space, so a
            // dot-on-face check verifies this transform and nothing else.
            let deviceSpacePoint = DeviceParameterGuard.unitPoint(
                center.map { CGPoint(x: $0.y, y: 1 - $0.x) } ?? CGPoint(x: 0.5, y: 0.5)
            )
            guard let target = deviceSpacePoint else { return }   // a garbage face box must not reach the device
            #if DEBUG
            // The crosshair draws THIS point back-converted through the layer.
            // Reached only when the guard above has PROVEN metering is active —
            // so publish unconditionally here. The STAND-DOWN transitions clear
            // the dot at their own sites (focus(atLayerPoint:) and
            // setAEAFLock(true)); publishing nil from inside those would read
            // queue-confined state from the main actor, and reading it HERE
            // from the Task body would too — the same violation class the
            // isScreenActive fix (#342) retired. State changes publish state;
            // nothing reads across homes.
            Task { @MainActor in
                self.lastFaceMeterDevicePoint = (center != nil) ? target : nil
            }
            #endif
            let faceActive = center != nil
            let faceChanged = faceActive != self.faceMeteringActive
            self.faceMeteringActive = faceActive
            // Rate-limit — but a face appearing/vanishing must update the bias
            // even when the meter point barely moves.
            if !faceChanged, let last = self.lastFaceExposurePoint,
               abs(last.x - target.x) < 0.08, abs(last.y - target.y) < 0.08 { return }
            guard (try? device.lockForConfiguration()) != nil else { return }
            CaptureExceptionShield.settings("setFaceExposure") {
                device.exposurePointOfInterest = target
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                // Slight under-expose while metering a face (blown highlights are
                // unrecoverable; lifted shadows are fine), on top of any card-
                // anchored calibration bias for this room's light.
                let bias = self.calibrationBiasEV + (center == nil ? 0 : CoachTuning.faceExposureBias)
                if let safe = DeviceParameterGuard.clamped(
                    bias, lower: device.minExposureTargetBias, upper: device.maxExposureTargetBias) {
                    device.setExposureTargetBias(safe)
                }
            }
            device.unlockForConfiguration()
            self.lastFaceExposurePoint = target
        }
    }

    /// Anchor exposure to the calibration card: EV bias so the card's neutral
    /// band renders at its reference luma in this room's light. Applied
    /// immediately and folded into every subsequent face-metering update.
    func setCalibrationExposureBias(_ ev: Float) {
        sessionQueue.async {
            guard let device = self.device else { return }
            // Sanitize at the STORE, not just the write: a NaN parked here would
            // go on poisoning the bias of every later face-metering update.
            if !ev.isFinite {
                // A degradation nobody can see is a bug that never gets fixed —
                // same doctrine as the exception shield. Log and neutralize.
                Self.cameraLog.warning("⚠️ calibration EV bias was non-finite (\(ev)); stored as 0")
                self.calibrationBiasEV = 0
            } else {
                self.calibrationBiasEV = ev
            }
            guard device.exposureMode != .locked,
                  (try? device.lockForConfiguration()) != nil else { return }
            let faceBias: Float = self.faceMeteringActive ? CoachTuning.faceExposureBias : 0
            CaptureExceptionShield.settings("setCalibrationExposureBias") {
                if let safe = DeviceParameterGuard.clamped(
                    self.calibrationBiasEV + faceBias,
                    lower: device.minExposureTargetBias, upper: device.maxExposureTargetBias) {
                    device.setExposureTargetBias(safe)
                }
            }
            device.unlockForConfiguration()
        }
    }

    /// Lock (or release) focus + exposure so the camera stops re-metering as hands
    /// and product move through the frame — the pro's "set it and shoot" control.
    func setAEAFLock(_ locked: Bool) {
        sessionQueue.async {
            guard let device = self.device,
                  (try? device.lockForConfiguration()) != nil else { return }
            CaptureExceptionShield.settings("setAEAFLock") {
                if locked {
                    if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                } else {
                    if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                }
                // The explicit lock supersedes any pending tap-to-focus revert.
                device.isSubjectAreaChangeMonitoringEnabled = false
            }
            device.unlockForConfiguration()
            self.userMeteringActive = false
            #if DEBUG
            // AE/AF lock stands face metering down (the setFaceExposure guard
            // returns early while exposure is locked) — clear the crosshair at
            // the transition, on the queue that owns the state.
            if locked {
                Task { @MainActor in self.lastFaceMeterDevicePoint = nil }
            }
            #endif
            Task { @MainActor in self.aeAfLocked = locked }
        }
    }

    // MARK: - White balance (gray-card calibration)

    /// Lock white balance so the room's color cast is neutralized — computed from a
    /// neutral (gray card / white towel) sample the pro fills the frame with. Gives
    /// true, consistent color for the profile / Looks feed. `sample` is the average
    /// linear-ish RGB (0…1) of the neutral patch.
    func lockWhiteBalance(sampleR: Double, sampleG: Double, sampleB: Double) {
        sessionQueue.async {
            guard let device = self.device else { return }
            // The neutralizing solve needs the device's CURRENT gains and max,
            // and both are only trustworthy inside the same still window that
            // holds the write — see `applyWhiteBalanceGains` for why.
            self.withSettledFormat {
                let current = device.deviceWhiteBalanceGains
                let target = CameraCalibration.neutralizingGains(
                    sample: RGB(sampleR, sampleG, sampleB),
                    current: RGB(Double(current.redGain), Double(current.greenGain), Double(current.blueGain)),
                    maxGain: Double(device.maxWhiteBalanceGain)
                )
                let outcome = GuardedWhiteBalance.apply(
                    r: target.r, g: target.g, b: target.b, to: device)
                self.handle(outcome, source: "lockWhiteBalance", persist: true)
            }
        }
    }

    /// Re-apply previously locked WB gains (persisted per booking) so the AFTER
    /// shoot uses the same calibration as the BEFORE without re-carding.
    /// 🔴 THE BUILD 38 CRASH SITE. Read `GuardedWhiteBalance.swift` before
    /// changing anything here.
    ///
    /// This runs milliseconds after `startRunning`, from the camera view's
    /// "one card, one session" re-apply — i.e. squarely inside the window where
    /// a virtual device is still settling its active constituent lens and the
    /// preview layer is attaching a connection on the main thread. Build 38
    /// validated the gains against the device as it was *before* that settled
    /// and wrote them *after*, and AVFoundation killed the process for it.
    ///
    /// Three things now stand between that and an abort: the write happens
    /// inside a session-configuration transaction so the format cannot change
    /// underneath it; every precondition is re-read inside the device lock; and
    /// the write itself is caught, so a raise degrades to automatic white
    /// balance instead of `SIGABRT`.
    func applyWhiteBalanceGains(r: Double, g: Double, b: Double) {
        sessionQueue.async {
            guard let device = self.device else { return }
            self.withSettledFormat {
                let outcome = GuardedWhiteBalance.apply(r: r, g: g, b: b, to: device)
                self.handle(outcome, source: "applyWhiteBalanceGains", persist: false)
            }
        }
    }

    /// Runs `body` inside a session configuration transaction, so the session
    /// cannot re-negotiate its active format — and a virtual device cannot swap
    /// its active constituent lens — while `body` reads the device's limits and
    /// writes to it.
    ///
    /// This is the root-cause half of the build 38 fix. `lockForConfiguration`
    /// alone does NOT close this window: it excludes other clients from
    /// configuring the device, not the session's own renegotiation, and a
    /// preview-layer attach on the main thread is exactly that renegotiation.
    ///
    /// sessionQueue-confined. `commitConfiguration` is shielded too, because it
    /// is itself a call AVFoundation can raise from.
    nonisolated private func withSettledFormat(_ body: () -> Void) {
        CaptureExceptionShield.perform("beginConfiguration") { self.session.beginConfiguration() }
        body()
        commitConfigurationShielded()
    }

    /// `commitConfiguration()` with exceptions caught. It validates the whole
    /// pending configuration and raises on an invalid one, so it is a throwing
    /// call like any other — and the one that must never be skipped, since an
    /// uncommitted transaction leaves the session wedged.
    nonisolated private func commitConfigurationShielded() {
        CaptureExceptionShield.perform("commitConfiguration") {
            self.session.commitConfiguration()
        }
    }

    /// Fold one white-balance attempt back into the UI + persisted calibration.
    ///
    /// Every case here leaves a running camera. `persist` is true only for a
    /// fresh gray-card lock — re-applying stored gains must not re-write them.
    nonisolated private func handle(
        _ outcome: WhiteBalanceOutcome, source: String, persist: Bool
    ) {
        if let reason = outcome.reason {
            // Caught, not fatal — but a caught throw here is still a bug, and
            // this is the line that will name it next time. AVFoundation's own
            // message says which precondition it enforced; the build 38 crash
            // log did not carry one, which is why round 3 had to infer it.
            Self.cameraLog.warning("⚠️ WB write via \(source, privacy: .public) raised; falling back to automatic white balance. \(reason, privacy: .public)")
        }
        switch outcome {
        case let .locked(r, g, b):
            Task { @MainActor in
                self.whiteBalanceCalibrated = true
                if persist { self.onWhiteBalanceLocked?(Double(r), Double(g), Double(b)) }
            }
        case .unusableGains:
            // Gains persisted by an older build that let a NaN through. They are
            // unusable and they are not going to become usable — say so, so the
            // calibration gets dropped instead of re-poisoning every future
            // launch of this camera.
            Task { @MainActor in
                self.whiteBalanceCalibrated = false
                self.onWhiteBalanceUnusable?()
            }
        case .unsupported, .lockUnavailable, .fellBackToAuto:
            // The shoot runs on automatic white balance — which is what it did
            // for months before calibration existed. The badge must say AUTO
            // rather than claim a calibration that is not in effect.
            Task { @MainActor in self.whiteBalanceCalibrated = false }
        }
    }

    /// Back to automatic white balance (drop the calibration — including any
    /// card-anchored exposure bias).
    func resetWhiteBalance() {
        sessionQueue.async {
            guard let device = self.device,
                  (try? device.lockForConfiguration()) != nil else { return }
            self.calibrationBiasEV = 0
            let faceBias: Float = self.faceMeteringActive ? CoachTuning.faceExposureBias : 0
            CaptureExceptionShield.settings("resetWhiteBalance") {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                if let safe = DeviceParameterGuard.clamped(
                    faceBias, lower: device.minExposureTargetBias, upper: device.maxExposureTargetBias) {
                    device.setExposureTargetBias(safe)
                }
            }
            device.unlockForConfiguration()
            Task { @MainActor in self.whiteBalanceCalibrated = false }
        }
    }

    // MARK: - Recording (silent video clips)

    func startRecording() {
        guard recordingAvailable, !isRecording else { return }
        isRecording = true
        sessionQueue.async {
            // Every bail below must roll `isRecording` back — the view's record
            // button branches on it, so a stuck `true` reroutes every later tap
            // into `stopRecording()` (which throws "not recording") and bricks
            // recording for the life of the camera screen.
            guard self.session.isRunning else {
                Task { @MainActor in self.isRecording = false }
                return
            }
            guard !self.movieOutput.isRecording else {
                // The output IS rolling but the UI thought otherwise — trust the
                // output and let the UI catch up rather than double-starting.
                Task { @MainActor in self.isRecording = true }
                return
            }
            CaptureExceptionShield.settings("startRecording/connection") {
                if let conn = self.movieOutput.connection(with: .video) {
                    // Upright portrait orientation (iOS 17 rotation API).
                    if conn.isVideoRotationAngleSupported(90) {
                        conn.videoRotationAngle = 90
                    }
                    // Stabilize. This was never set, so it defaulted to OFF and
                    // every handheld salon clip shipped shaky — in a room where the
                    // pro is holding the phone one-handed over a client. `.auto`
                    // lets the device pick the strongest mode its format supports.
                    if conn.isVideoStabilizationSupported {
                        conn.preferredVideoStabilizationMode = .auto
                    }
                }
                // Cap the take. With no cap, a long clip means a long card-correction
                // re-export (per-frame CIColorMatrix at highest quality), a large temp
                // file and a large upload — on a phone that is also running the coach.
                self.movieOutput.maxRecordedDuration = CMTime(
                    seconds: Self.maxClipSeconds, preferredTimescale: 600)
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("tovis-clip-\(UUID().uuidString).mov")
            // A raise here means no delegate callback, so the UI must not be
            // left showing a recording that never started.
            if CaptureExceptionShield.perform("startRecording", {
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
            }).didThrow {
                Task { @MainActor in self.isRecording = false }
            }
        }
    }

    /// Stop and hand back the recorded file URL.
    ///
    /// Watchdog, same shape as the photo capture's: if the delegate callback is
    /// silently dropped (an output glitch, an interruption mid-take), fail the
    /// awaiting caller after a beat instead of stranding it forever. Gated on a
    /// generation token so a stale watchdog can't resolve a newer take that has
    /// since reused the continuation slot.
    ///
    /// Testable invariant: a watchdog whose stop ALREADY resolved (delegate
    /// arrived, or the raise path fired) is a complete no-op — it must not
    /// touch `isRecording` under a subsequent take that began within the 10s
    /// window, because an unresolved stop is exactly what a still-set
    /// `recordContinuation` proves.
    func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            sessionQueue.async {
                guard self.movieOutput.isRecording else {
                    cont.resume(throwing: CameraError.noData)
                    return
                }
                self.recordToken &+= 1
                let token = self.recordToken
                self.recordContinuation = cont
                if CaptureExceptionShield.perform("stopRecording", {
                    self.movieOutput.stopRecording()
                }).didThrow {
                    // No `didFinishRecordingTo` will arrive — fail the awaiting
                    // caller now rather than stranding it forever.
                    self.recordContinuation = nil
                    cont.resume(throwing: CameraError.noData)
                    return
                }
                self.sessionQueue.asyncAfter(deadline: .now() + Self.recordWatchdog) { [weak self] in
                    // Weak capture bound to `controller` (not re-binding
                    // `self`) — same reason as capturePhoto's watchdog: the
                    // enclosing block holds `self` strongly, and the ownership
                    // contrast on the same name reads as a compiler mismatch.
                    guard let controller = self, controller.recordToken == token else { return }
                    // `recordContinuation` still being set is the PROOF this stop
                    // never resolved — the delegate cleared it on arrival, and
                    // `recordToken` is only bumped by a NEW stopRecording, which
                    // stores a fresh continuation. Only then is recovery due:
                    // roll `isRecording` back AND fail the awaiter. (A watchdog
                    // firing after a resolved stop must do nothing, or it clears
                    // the flag under a subsequent take that started within 10s.)
                    guard let cont = controller.recordContinuation else { return }
                    controller.recordContinuation = nil
                    Task { @MainActor in controller.isRecording = false }
                    cont.resume(throwing: CameraError.timedOut)
                }
            }
        }
    }

    // MARK: - Setup

    /// Stills bigger than this balloon every downstream decode/upload (QC, card
    /// correction, strip thumbnails) with no visible gain on the feed or the
    /// profile — the transients that piled into the jetsam kills.
    /// Read by `maxPhotoDimensions`, which runs on the session queue.
    nonisolated private static let photoPixelCap = 24_500_000

    /// The largest still size at/under the cap that a format ACTUALLY OFFERS,
    /// else the smallest it offers. Nil when it offers nothing.
    ///
    /// ⚠️ The result must always be one of `supported`, never a value derived
    /// from it: `AVCapturePhotoOutput.maxPhotoDimensions` answers a size the
    /// active format doesn't list with an **ObjC exception**, and Swift cannot
    /// catch those — so a wrong answer here is not a degraded camera, it is the
    /// app dying the instant the pro taps it.
    ///
    /// `supported` is deliberately treated as UNORDERED. The old reading —
    /// "the last one under the cap" — is only the largest-under-the-cap if the
    /// device lists ascending, which nothing promises. It held for the single
    /// wide-angle camera this was written against; #268 adopted the virtual
    /// triple / dual-wide devices, which report richer lists, and the same line
    /// then silently means "the last one under the cap that happens to sit
    /// before a bigger one".
    nonisolated static func maxPhotoDimensions(
        for supported: [CMVideoDimensions]
    ) -> CMVideoDimensions? {
        let pixels = { (d: CMVideoDimensions) in Int(d.width) * Int(d.height) }
        if let best = supported.filter({ pixels($0) <= photoPixelCap }).max(by: { pixels($0) < pixels($1) }) {
            return best
        }
        return supported.min(by: { pixels($0) < pixels($1) })
    }

    // MARK: - Device selection

    /// The back camera to shoot with, best first.
    ///
    /// The session used to take `builtInWideAngleCamera` only, which meant no
    /// macro auto-switch, no ultra-wide and no zoom anywhere in the stack — and
    /// the nails guide asked for "macro on one nail", a shot that physically
    /// cannot focus on a wide-angle-only device. A VIRTUAL device (triple /
    /// dual-wide / dual) is one input that auto-switches between its
    /// constituents, so close focus and zoom become available without the app
    /// managing lenses. The single wide camera stays the last resort.
    nonisolated static func preferredCaptureDevice() -> AVCaptureDevice? {
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,     // ultra-wide + wide + tele — macro auto-switch
            .builtInDualWideCamera,   // ultra-wide + wide — macro auto-switch
            .builtInDualCamera,       // wide + tele
            .builtInWideAngleCamera,
        ]
        for type in preferred {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// The zoom factor that parks a virtual device on its WIDE-ANGLE
    /// constituent, i.e. reproduces exactly the framing the single wide camera
    /// gave before the switch to a virtual device.
    ///
    /// This matters and is easy to get wrong: on a triple camera, zoom factor
    /// 1.0 is the ULTRA-WIDE. Adopting the virtual device without this would
    /// silently make every shot in the app 0.5×, which is a far bigger visible
    /// change than the capability it was adopted for.
    ///
    /// `switchOverFactors` (`virtualDeviceSwitchOverVideoZoomFactors`) has one
    /// entry per boundary between consecutive constituents, widest first — so
    /// the factor that first selects constituent `k` is entry `k − 1`.
    nonisolated static func wideAngleZoomFactor(
        wideIndex: Int, switchOverFactors: [CGFloat]
    ) -> CGFloat {
        guard wideIndex > 0 else { return 1.0 }   // already the widest constituent
        guard wideIndex - 1 < switchOverFactors.count else { return 1.0 }
        let factor = switchOverFactors[wideIndex - 1]
        return factor > 0 ? factor : 1.0
    }

    /// Park a virtual device on its wide-angle constituent so adopting one
    /// doesn't change the default framing of every shot in the app.
    nonisolated private static func matchWideAngleFraming(_ device: AVCaptureDevice) {
        guard let factor = wideAngleParkingFactor(device: device),
              (try? device.lockForConfiguration()) != nil else { return }
        CaptureExceptionShield.settings("videoZoomFactor") {
            if let safe = DeviceParameterGuard.clamped(
                factor,
                lower: device.minAvailableVideoZoomFactor,
                upper: device.maxAvailableVideoZoomFactor) {
                device.videoZoomFactor = safe
            }
        }
        device.unlockForConfiguration()
    }

    /// sRGB, explicitly — see the session-level note in `configureSession`.
    nonisolated private static func pinColorSpace(_ device: AVCaptureDevice) {
        guard device.activeFormat.supportedColorSpaces.contains(.sRGB),
              (try? device.lockForConfiguration()) != nil else { return }
        CaptureExceptionShield.settings("activeColorSpace") {
            device.activeColorSpace = .sRGB
        }
        device.unlockForConfiguration()
    }

    /// The three settings that are only meaningful once the session has SETTLED
    /// on the format it will run — the still-size ceiling, the capture colour
    /// space, and the virtual device's wide-angle parking zoom.
    ///
    /// Called on the session queue after `configureSession`'s commit, and does
    /// its own `beginConfiguration`/`commitConfiguration` so each read of
    /// `device.activeFormat` describes the format that is actually active. Each
    /// value is also checked against that format's own supported list rather
    /// than assumed: the three properties here are the entry path's only ObjC
    /// exceptions, and an exception is an instant process kill with no preview
    /// ever drawn — the shape of the report this fix came from.
    nonisolated private func applyFormatDependentSettings(device: AVCaptureDevice) {
        withSettledFormat {
            // Per-capture `settings.maxPhotoDimensions` may not exceed the output's,
            // so both derive from this one choice — see `capturePhoto`.
            CaptureExceptionShield.settings("maxPhotoDimensions") {
                if let dims = Self.maxPhotoDimensions(for: device.activeFormat.supportedMaxPhotoDimensions) {
                    self.photoOutput.maxPhotoDimensions = dims
                }
            }
            Self.pinColorSpace(device)
            Self.matchWideAngleFraming(device)
        }
    }

    private static func ensureAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Configure inputs/outputs on the session queue. Returns an error message
    /// on failure, nil on success.
    private func configureSession(
        frameDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?
    ) async -> String? {
        // Handing the coach's frame delegate to the session queue is a genuine
        // non-Sendable transfer that the type system cannot verify, so it is
        // named here rather than hidden behind `@preconcurrency import`.
        //
        // Why it is sound: this reference is only ever STORED. It is never
        // called from this queue. `setSampleBufferDelegate(_:queue:)` below is
        // told to deliver every buffer on `frameQueue`, so the delegate's own
        // code runs on exactly one queue for the life of the session — which is
        // the invariant `CoachAnalyzer` is written against.
        let delegateBox = UncheckedSendableBox(frameDelegate)
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            sessionQueue.async {
                // The delegate is STORED here, on the queue that owns it, rather
                // than assigned on the main actor and read from here.
                if let frameDelegate = delegateBox.value { self.frameDelegate = frameDelegate }
                CaptureExceptionShield.perform("beginConfiguration") {
                    self.session.beginConfiguration()
                }
                // `.photo` is supported everywhere the app runs, but an
                // unsupported preset is another uncatchable ObjC exception, and
                // this file no longer takes that bet anywhere.
                CaptureExceptionShield.settings("sessionPreset") {
                    if self.session.canSetSessionPreset(.photo) {
                        self.session.sessionPreset = .photo
                    }
                }
                // Pin the capture colour space. Left to its default, the
                // session auto-configures wide colour, so captures ship tagged
                // Display P3 — while `CardCorrection.applySync` re-encodes
                // explicitly to sRGB. Whether a card had been scanned therefore
                // changed the colour space of the shipped JPEG, WITHIN one
                // shoot if the pro scanned mid-session. sRGB for both: it is
                // what the correction path already produces and what the feed
                // and every social platform assume.
                self.session.automaticallyConfiguresCaptureDeviceForWideColor = false

                guard
                    let device = Self.preferredCaptureDevice(),
                    let input = try? AVCaptureDeviceInput(device: device),
                    self.session.canAddInput(input)
                else {
                    self.commitConfigurationShielded()
                    cont.resume(returning: "No camera available.")
                    return
                }
                // `canAddInput` said yes, but a raise here is still fatal to the
                // session rather than merely to one setting — so it reports a
                // failed camera instead of leaving a half-built session running.
                guard !CaptureExceptionShield.perform("addInput", {
                    self.session.addInput(input)
                }).didThrow else {
                    self.commitConfigurationShielded()
                    cont.resume(returning: "No camera available.")
                    return
                }
                self.device = device

                guard self.session.canAddOutput(self.photoOutput),
                      !CaptureExceptionShield.perform("addOutput(photo)", {
                          self.session.addOutput(self.photoOutput)
                      }).didThrow
                else {
                    self.commitConfigurationShielded()
                    cont.resume(returning: "Camera output unavailable.")
                    return
                }
                // Prioritize quality — these stills go on the pro's profile + the
                // Looks feed, so favor the best capture over speed.
                CaptureExceptionShield.settings("maxPhotoQualityPrioritization") {
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                }

                // Live frames for the on-device coach (optional).
                if let frameDelegate = self.frameDelegate, self.session.canAddOutput(self.videoOutput) {
                    CaptureExceptionShield.settings("addOutput(video)") {
                        self.videoOutput.alwaysDiscardsLateVideoFrames = true
                        self.videoOutput.setSampleBufferDelegate(frameDelegate, queue: self.frameQueue)
                        self.session.addOutput(self.videoOutput)
                    }
                }

                // Silent video recording (iOS 16+ allows movie + data outputs).
                if self.session.canAddOutput(self.movieOutput),
                   !CaptureExceptionShield.perform("addOutput(movie)", {
                       self.session.addOutput(self.movieOutput)
                   }).didThrow {
                    Task { @MainActor in self.recordingAvailable = true }
                }

                self.registerObservers(device: device)
                self.commitConfigurationShielded()
                // Owned by this queue, set on this queue — `start()` asks for it
                // through `onSessionQueue` rather than reading it from the main actor.
                self.configured = true
                if device.hasTorch {
                    Task { @MainActor in self.torchAvailable = true }
                }

                // ⚠️ EVERYTHING THAT READS `activeFormat` HAPPENS HERE, AFTER
                // THE COMMIT — never in the pass above.
                //
                // The session picks the device's active format to satisfy the
                // preset AND the set of outputs attached to it, and it settles
                // that choice when the configuration is COMMITTED. Reading
                // `device.activeFormat` between `beginConfiguration` and
                // `commitConfiguration` therefore reads the format from before
                // the negotiation, and every value derived from it is a value
                // for a format that may not be the one the camera ends up
                // running — which is fatal rather than merely wrong, because
                // both properties set from it answer an unsupported value with
                // an ObjC exception Swift cannot catch.
                //
                // This was survivable while the input was always the single
                // wide-angle camera: one camera, one obvious format, before and
                // after agreed. #268 adopted the virtual triple / dual-wide
                // devices, whose format negotiation is exactly what a movie
                // output and a video-data output added alongside a photo output
                // make non-trivial — so the two reads stopped agreeing on
                // hardware that has a second lens, which is every phone a pro
                // actually shoots on and no simulator.
                self.applyFormatDependentSettings(device: device)
                cont.resume(returning: nil)
            }
        }
    }

    /// One-time notification wiring, called from `configureSession` on the
    /// session queue: revert tap-to-focus when the scene changes, and surface
    /// session interruptions (phone call, camera claimed elsewhere) instead of
    /// leaving a frozen preview that still claims to be ready.
    nonisolated private func registerObservers(device: AVCaptureDevice) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification,
            object: device, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async { self.restoreContinuousFocus() }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: nil
        ) { [weak self] _ in
            // Bind the weak reference HERE, not inside the Task — referencing the
            // captured optional from concurrently-executing code is an error under
            // the Swift 6 language mode.
            guard let self else { return }
            Task { @MainActor in
                guard self.status == .ready else { return }
                self.status = .interrupted
            }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                // Only restart if the screen still wants the session running.
                // `stop()` (the review sheet) clears that flag; a queued
                // interruption-ended landing afterwards must not resurrect the
                // session behind the sheet — `resume()` owns restarting then.
                guard self.isScreenActive, self.configured, !self.session.isRunning else { return }
                CaptureExceptionShield.perform("startRunning(interruptionEnded)") { self.session.startRunning() }
                Task { @MainActor in
                    if self.status == .interrupted { self.status = .ready }
                }
            }
        })
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    /// Whether a finish-callback error is the benign "hit `maxRecordedDuration`"
    /// case. AVFoundation delivers that error WITH a complete, playable file —
    /// Apple's contract is to consult `AVErrorRecordingSuccessfullyFinishedKey`
    /// before treating any error as fatal (see the AVCam sample). Treating the
    /// cap as failure used to throw away exactly 60 seconds of finished footage.
    ///
    /// Precedence: an explicit system "successfully finished" verdict wins;
    /// otherwise OUR OWN duration cap is success by construction (the file was
    /// closed at a limit we set — observed flag values alongside it vary by OS,
    /// so the flag does not get the final say there); anything else failed.
    nonisolated static func recordingSucceeded(despite error: Error?) -> Bool {
        guard let error = error as NSError? else { return true }
        if let completed = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool,
           completed { return true }
        if (error.domain, error.code) == (AVError.errorDomain, AVError.maximumDurationReached.rawValue) {
            return true
        }
        return false
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // A max-duration take IS a kept take — the file on disk is complete.
        let failed = !Self.recordingSucceeded(despite: error)
        if failed, let error {
            Self.cameraLog.warning("⚠️ clip failed to record: \(error.localizedDescription, privacy: .public)")
        }
        sessionQueue.async {
            let cont = self.recordContinuation
            self.recordContinuation = nil
            Task { @MainActor in self.isRecording = false }
            if failed {
                cont?.resume(throwing: CameraError.noData)
                // The tmp file holds nothing usable — release it rather than
                // leaving failed takes to pile up in tmp all day.
                try? FileManager.default.removeItem(at: outputFileURL)
            } else if let cont {
                cont.resume(returning: outputFileURL)
            } else {
                // A take that ended BY ITSELF (the duration cap firing mid-shoot
                // is the normal case — nobody called stopRecording) has no
                // awaiter. The file is complete and kept; hand it to the view's
                // custody hook rather than orphaning it in tmp.
                Task { @MainActor in self.onUnawaitedClipFinished?(outputFileURL) }
            }
        }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        // Extract the bytes here (off the non-Sendable AVCapturePhoto), then hand
        // the continuation back on the session queue where it was set.
        let bytes = photo.fileDataRepresentation()
        sessionQueue.async {
            if let error {
                self.resolveCapture(.failure(error))
            } else if let bytes {
                self.resolveCapture(.success(bytes))
            } else {
                self.resolveCapture(.failure(CameraError.noData))
            }
        }
    }
}
