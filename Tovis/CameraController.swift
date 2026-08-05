// A minimal custom camera over AVFoundation: live preview + still capture → JPEG.
//
// Built custom (not the system PhotosPicker) on purpose: the "AI photographer"
// taps the live frame buffer (AVCaptureVideoDataOutput) for the on-device coach
// (lighting / composition / background / pose) and draws overlays on the preview.
// Capture, recording, and the live coaching hook all ship here today — the coach
// itself lives in CoachEngine.
import AVFoundation
import SwiftUI
import TovisKit

enum CameraError: Error { case noData, captureInProgress, timedOut }

@Observable
@MainActor
final class CameraController: NSObject {
    enum Status: Equatable { case idle, configuring, ready, interrupted, denied, failed(String) }

    private(set) var status: Status = .idle

    // The AVFoundation objects are confined to `sessionQueue`. They're marked
    // nonisolated(unsafe) so the queue closures can touch them without tripping
    // the project's default-MainActor isolation — the serial queue is the real
    // guard. `session` is read by CameraPreview (nonisolated → safe to read).
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let videoOutput = AVCaptureVideoDataOutput()
    /// The active capture device — kept so tap-to-focus / AE-AF lock can configure
    /// its focus + exposure.
    nonisolated(unsafe) private var device: AVCaptureDevice?
    /// The live preview layer, for converting tap points to device coordinates.
    nonisolated(unsafe) weak var previewLayer: AVCaptureVideoPreviewLayer?
    /// Whether focus + exposure are currently locked (AE/AF lock).
    private(set) var aeAfLocked = false
    /// Whether white balance is locked to a calibrated (gray-card) value.
    private(set) var whiteBalanceCalibrated = false
    /// Fired (on the main actor) with the final locked WB gains — the camera
    /// view persists them per booking so before + after share one calibration.
    var onWhiteBalanceLocked: ((Double, Double, Double) -> Void)?
    /// Records silent video clips (NO mic input — we never capture salon audio).
    nonisolated(unsafe) private let movieOutput = AVCaptureMovieFileOutput()
    nonisolated(unsafe) private var configured = false
    nonisolated(unsafe) private var captureContinuation: CheckedContinuation<Data, Error>?
    /// Bumped per capture so a stale watchdog for a finished shot can't resolve a
    /// newer capture that has since reused the continuation slot. sessionQueue.
    nonisolated(unsafe) private var captureToken = 0
    /// Longest we wait on a still's delegate callback before failing the awaiting
    /// continuation, so a capture the system silently drops can't strand the
    /// shutter (and leave `uploading` gating the whole UI shut) forever.
    private static let captureWatchdog: TimeInterval = 10
    /// Longest single clip. A product number, not a measurement: a salon clip
    /// that earns its place is a few seconds of movement, and everything
    /// downstream (colour re-export, temp file, upload) scales with length.
    /// The clip's RESOLUTION, frame rate and codec are still inherited from the
    /// `.photo` preset and are deliberately left alone until the device pass
    /// measures what they actually are (`docs/design/camera-excellence-plan.md`
    /// §3.6) — changing the codec blind would risk web playback.
    static let maxClipSeconds: Double = 60
    nonisolated(unsafe) private var recordContinuation: CheckedContinuation<URL, Error>?
    /// Whether the session could add the movie output (false → recording hidden).
    private(set) var recordingAvailable = false
    private(set) var isRecording = false
    /// Live-frame delegate for the on-device coach (set before `start`). Weak —
    /// the CoachEngine owns it.
    nonisolated(unsafe) weak var frameDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?
    /// Notification tokens (subject-area change + session interruption), removed
    /// on deinit.
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []
    private let sessionQueue = DispatchQueue(label: "tovis.camera.session")
    private let frameQueue = DispatchQueue(label: "tovis.camera.frames")

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Request permission, configure once, and start the preview. Idempotent.
    /// Pass `frameDelegate` to feed the on-device coach the live frames.
    func start(frameDelegate: AVCaptureVideoDataOutputSampleBufferDelegate? = nil) async {
        if let frameDelegate { self.frameDelegate = frameDelegate }
        guard await Self.ensureAuthorized() else { status = .denied; return }

        if !configured {
            status = .configuring
            if let failure = await configureSession() {
                status = .failed(failure)
                return
            }
            configured = true
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
                cont.resume()
            }
        }
        status = .ready
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Resume a session that was paused with `stop()` — without re-running auth /
    /// reconfiguration. Used when the pro returns from reviewing captured shots so
    /// the camera only runs while they're actually shooting (not behind a sheet,
    /// where it would keep scoring + auto-harvesting). No-op until configured.
    func resume() {
        sessionQueue.async {
            guard self.configured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    /// Capture a still → JPEG `Data`.
    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            sessionQueue.async {
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
                    settings.maxPhotoDimensions = outputMax
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
                // Watchdog: if neither capture delegate fires (a shot the system
                // silently drops — session interrupted mid-capture, an output
                // glitch), fail this capture after a beat so the caller recovers.
                // Gated on the token so it can't clobber a later capture that has
                // since reused the slot.
                self.sessionQueue.asyncAfter(deadline: .now() + Self.captureWatchdog) { [weak self] in
                    guard let self, self.captureToken == token else { return }
                    self.resolveCapture(.failure(CameraError.timedOut))
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
        guard let device, let layer = previewLayer else { return }
        let point = layer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.unlockForConfiguration()
            self.userMeteringActive = true   // face metering stands down
            Task { @MainActor in self.aeAfLocked = false }
        }
    }

    /// Scene changed after a tap-to-focus — hand focus/exposure back to the
    /// continuous system so the camera tracks the shoot again. Runs on
    /// `sessionQueue`. (An engaged AE/AF lock turns monitoring off, so this
    /// never fights the lock.)
    nonisolated private func restoreContinuousFocus() {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.isSubjectAreaChangeMonitoringEnabled = false
        device.unlockForConfiguration()
        userMeteringActive = false
    }

    // MARK: - Face-priority exposure

    /// A user tap-to-focus meter is in play (until the scene moves on) — face
    /// metering stands down so it doesn't fight the pro's explicit intent.
    /// sessionQueue-confined.
    nonisolated(unsafe) private var userMeteringActive = false
    /// Last face point we metered at (device space), to rate-limit updates.
    nonisolated(unsafe) private var lastFaceExposurePoint: CGPoint?
    /// Whether a face is currently driving the meter (the no-face fallback
    /// point is dead center, so the point alone can't tell). sessionQueue-confined.
    nonisolated(unsafe) private var faceMeteringActive = false
    /// Card-anchored exposure: EV bias from the calibration card's neutral band
    /// ("this gray must render at reference luma in THIS room's light").
    /// Composes with the face-metering highlight bias. sessionQueue-confined.
    nonisolated(unsafe) private var calibrationBiasEV: Float = 0

    /// Continuously meter exposure for the subject's face — what a photographer
    /// does by default, and what silently fixes "too dark" / "backlit" instead
    /// of asking the pro to. `center` is the face center in upright,
    /// top-left-normalized frame coords (nil = no face → back to center-weighted).
    /// Stands down while AE/AF is locked or a tap-to-focus meter is active.
    /// Fed by the coach's per-frame face detection (already running).
    func setFaceExposure(center: CGPoint?) {
        guard let device else { return }
        sessionQueue.async {
            guard !self.userMeteringActive,
                  device.exposureMode != .locked,
                  device.isExposurePointOfInterestSupported else { return }
            // Upright top-left (x, y) → device space (sensor landscape-right,
            // top-left origin): (y, 1 − x). ⚠️ Verify on hardware, like the
            // level sign — sensor mounting can flip this.
            let target = center.map { CGPoint(x: $0.y, y: 1 - $0.x) } ?? CGPoint(x: 0.5, y: 0.5)
            let faceActive = center != nil
            let faceChanged = faceActive != self.faceMeteringActive
            self.faceMeteringActive = faceActive
            // Rate-limit — but a face appearing/vanishing must update the bias
            // even when the meter point barely moves.
            if !faceChanged, let last = self.lastFaceExposurePoint,
               abs(last.x - target.x) < 0.08, abs(last.y - target.y) < 0.08 { return }
            guard (try? device.lockForConfiguration()) != nil else { return }
            device.exposurePointOfInterest = target
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            // Slight under-expose while metering a face (blown highlights are
            // unrecoverable; lifted shadows are fine), on top of any card-
            // anchored calibration bias for this room's light.
            let bias = self.calibrationBiasEV + (center == nil ? 0 : CoachTuning.faceExposureBias)
            device.setExposureTargetBias(
                min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias))
            device.unlockForConfiguration()
            self.lastFaceExposurePoint = target
        }
    }

    /// Anchor exposure to the calibration card: EV bias so the card's neutral
    /// band renders at its reference luma in this room's light. Applied
    /// immediately and folded into every subsequent face-metering update.
    func setCalibrationExposureBias(_ ev: Float) {
        guard let device else { return }
        sessionQueue.async {
            self.calibrationBiasEV = ev
            guard device.exposureMode != .locked,
                  (try? device.lockForConfiguration()) != nil else { return }
            let faceBias: Float = self.faceMeteringActive ? CoachTuning.faceExposureBias : 0
            device.setExposureTargetBias(
                min(max(ev + faceBias, device.minExposureTargetBias), device.maxExposureTargetBias))
            device.unlockForConfiguration()
        }
    }

    /// Lock (or release) focus + exposure so the camera stops re-metering as hands
    /// and product move through the frame — the pro's "set it and shoot" control.
    func setAEAFLock(_ locked: Bool) {
        guard let device else { return }
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if locked {
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            } else {
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            }
            // The explicit lock supersedes any pending tap-to-focus revert.
            device.isSubjectAreaChangeMonitoringEnabled = false
            device.unlockForConfiguration()
            self.userMeteringActive = false
            Task { @MainActor in self.aeAfLocked = locked }
        }
    }

    // MARK: - White balance (gray-card calibration)

    /// Lock white balance so the room's color cast is neutralized — computed from a
    /// neutral (gray card / white towel) sample the pro fills the frame with. Gives
    /// true, consistent color for the profile / Looks feed. `sample` is the average
    /// linear-ish RGB (0…1) of the neutral patch.
    func lockWhiteBalance(sampleR: Double, sampleG: Double, sampleB: Double) {
        guard let device else { return }
        sessionQueue.async {
            guard device.isWhiteBalanceModeSupported(.locked),
                  (try? device.lockForConfiguration()) != nil else { return }
            let current = device.deviceWhiteBalanceGains
            let maxGain = device.maxWhiteBalanceGain
            let target = CameraCalibration.neutralizingGains(
                sample: RGB(sampleR, sampleG, sampleB),
                current: RGB(Double(current.redGain), Double(current.greenGain), Double(current.blueGain)),
                maxGain: Double(maxGain)
            )
            func clamp(_ x: Double) -> Float { min(max(Float(x), 1), maxGain) }
            let gains = AVCaptureDevice.WhiteBalanceGains(
                redGain: clamp(target.r), greenGain: clamp(target.g), blueGain: clamp(target.b))
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            device.unlockForConfiguration()
            Task { @MainActor in
                self.whiteBalanceCalibrated = true
                self.onWhiteBalanceLocked?(Double(gains.redGain), Double(gains.greenGain), Double(gains.blueGain))
            }
        }
    }

    /// Re-apply previously locked WB gains (persisted per booking) so the AFTER
    /// shoot uses the same calibration as the BEFORE without re-carding.
    func applyWhiteBalanceGains(r: Double, g: Double, b: Double) {
        guard let device else { return }
        sessionQueue.async {
            guard device.isWhiteBalanceModeSupported(.locked),
                  (try? device.lockForConfiguration()) != nil else { return }
            let maxGain = device.maxWhiteBalanceGain
            func clamp(_ x: Double) -> Float { min(max(Float(x), 1), maxGain) }
            let gains = AVCaptureDevice.WhiteBalanceGains(
                redGain: clamp(r), greenGain: clamp(g), blueGain: clamp(b))
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            device.unlockForConfiguration()
            Task { @MainActor in self.whiteBalanceCalibrated = true }
        }
    }

    /// Back to automatic white balance (drop the calibration — including any
    /// card-anchored exposure bias).
    func resetWhiteBalance() {
        guard let device else { return }
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            self.calibrationBiasEV = 0
            let faceBias: Float = self.faceMeteringActive ? CoachTuning.faceExposureBias : 0
            device.setExposureTargetBias(
                min(max(faceBias, device.minExposureTargetBias), device.maxExposureTargetBias))
            device.unlockForConfiguration()
            Task { @MainActor in self.whiteBalanceCalibrated = false }
        }
    }

    // MARK: - Recording (silent video clips)

    func startRecording() {
        guard recordingAvailable, !isRecording else { return }
        isRecording = true
        sessionQueue.async {
            guard self.session.isRunning, !self.movieOutput.isRecording else { return }
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
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("tovis-clip-\(UUID().uuidString).mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    /// Stop and hand back the recorded file URL.
    func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            sessionQueue.async {
                guard self.movieOutput.isRecording else {
                    cont.resume(throwing: CameraError.noData)
                    return
                }
                self.recordContinuation = cont
                self.movieOutput.stopRecording()
            }
        }
    }

    // MARK: - Setup

    /// The largest still dimensions we'll shoot for a device's active format:
    /// the biggest at/under ~24 MP (full-sensor 48 MP stills just balloon every
    /// downstream decode/upload with no feed/profile gain), else the smallest
    /// offered. Both the photo output's ceiling and each capture's `settings`
    /// derive from this so they always agree — see `capturePhoto`.
    nonisolated private static func cappedPhotoDimensions(for device: AVCaptureDevice) -> CMVideoDimensions? {
        let dims = device.activeFormat.supportedMaxPhotoDimensions
        return dims.last(where: { Int($0.width) * Int($0.height) <= 24_500_000 }) ?? dims.first
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
        let constituents = device.constituentDevices
        guard !constituents.isEmpty,
              let wideIndex = constituents.firstIndex(where: { $0.deviceType == .builtInWideAngleCamera })
        else { return }
        let factor = wideAngleZoomFactor(
            wideIndex: wideIndex,
            switchOverFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) })
        guard factor > 1.0, (try? device.lockForConfiguration()) != nil else { return }
        device.videoZoomFactor = min(max(factor, device.minAvailableVideoZoomFactor),
                                     device.maxAvailableVideoZoomFactor)
        device.unlockForConfiguration()
    }

    /// sRGB, explicitly — see the session-level note in `configureSession`.
    nonisolated private static func pinColorSpace(_ device: AVCaptureDevice) {
        guard device.activeFormat.supportedColorSpaces.contains(.sRGB),
              (try? device.lockForConfiguration()) != nil else { return }
        device.activeColorSpace = .sRGB
        device.unlockForConfiguration()
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
    private func configureSession() async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            sessionQueue.async {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
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
                    self.session.commitConfiguration()
                    cont.resume(returning: "No camera available.")
                    return
                }
                self.session.addInput(input)
                self.device = device
                Self.pinColorSpace(device)
                Self.matchWideAngleFraming(device)

                guard self.session.canAddOutput(self.photoOutput) else {
                    self.session.commitConfiguration()
                    cont.resume(returning: "Camera output unavailable.")
                    return
                }
                self.session.addOutput(self.photoOutput)
                // Prioritize quality — these stills go on the pro's profile + the
                // Looks feed, so favor the best capture over speed.
                self.photoOutput.maxPhotoQualityPrioritization = .quality
                // Declare the output's max still dimensions up front. Per-capture
                // `settings.maxPhotoDimensions` may not exceed this, so both are
                // set from the same cap (else `capturePhoto` throws). Capped at
                // ~24 MP: full-sensor 48 MP stills balloon every downstream
                // decode/upload with no feed/profile gain.
                if let dims = Self.cappedPhotoDimensions(for: device) {
                    self.photoOutput.maxPhotoDimensions = dims
                }

                // Live frames for the on-device coach (optional).
                if let frameDelegate = self.frameDelegate, self.session.canAddOutput(self.videoOutput) {
                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoOutput.setSampleBufferDelegate(frameDelegate, queue: self.frameQueue)
                    self.session.addOutput(self.videoOutput)
                }

                // Silent video recording (iOS 16+ allows movie + data outputs).
                if self.session.canAddOutput(self.movieOutput) {
                    self.session.addOutput(self.movieOutput)
                    Task { @MainActor in self.recordingAvailable = true }
                }

                self.registerObservers(device: device)
                self.session.commitConfiguration()
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
            Task { @MainActor in
                guard let self, self.status == .ready else { return }
                self.status = .interrupted
            }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                if self.configured, !self.session.isRunning { self.session.startRunning() }
                Task { @MainActor in
                    if self.status == .interrupted { self.status = .ready }
                }
            }
        })
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let failed = error != nil
        sessionQueue.async {
            let cont = self.recordContinuation
            self.recordContinuation = nil
            Task { @MainActor in self.isRecording = false }
            if failed {
                cont?.resume(throwing: CameraError.noData)
            } else {
                cont?.resume(returning: outputFileURL)
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
