// A minimal custom camera over AVFoundation: live preview + still capture → JPEG.
//
// Built custom (not the system PhotosPicker) on purpose: Phase B of the "AI
// photographer" taps the live frame buffer for the on-device coach (lighting /
// composition / background / pose) and draws overlays on the preview. For Phase A
// this is capture-only; the AVCaptureVideoDataOutput coaching hook lands in B.
import AVFoundation
import SwiftUI
import TovisKit

enum CameraError: Error { case noData, captureInProgress }

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
    /// Records silent video clips (NO mic input — we never capture salon audio).
    nonisolated(unsafe) private let movieOutput = AVCaptureMovieFileOutput()
    nonisolated(unsafe) private var configured = false
    nonisolated(unsafe) private var captureContinuation: CheckedContinuation<Data, Error>?
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
                // Force JPEG so the bytes match the "image/jpeg" content-type we
                // presign with (the device default can be HEIC).
                let settings: AVCapturePhotoSettings
                if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                // Best possible still for the profile / Looks feed: full sensor
                // resolution + quality-prioritized processing.
                settings.photoQualityPrioritization = .quality
                if let dims = self.device?.activeFormat.supportedMaxPhotoDimensions.last {
                    settings.maxPhotoDimensions = dims
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
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
            Task { @MainActor in self.whiteBalanceCalibrated = true }
        }
    }

    /// Back to automatic white balance (drop the calibration).
    func resetWhiteBalance() {
        guard let device else { return }
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
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
            guard self.session.isRunning, !self.movieOutput.isRecording else { return }
            // Upright portrait orientation (iOS 17 rotation API).
            if let conn = self.movieOutput.connection(with: .video),
               conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90
            }
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

                guard
                    let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                        ?? AVCaptureDevice.default(for: .video),
                    let input = try? AVCaptureDeviceInput(device: device),
                    self.session.canAddInput(input)
                else {
                    self.session.commitConfiguration()
                    cont.resume(returning: "No camera available.")
                    return
                }
                self.session.addInput(input)
                self.device = device

                guard self.session.canAddOutput(self.photoOutput) else {
                    self.session.commitConfiguration()
                    cont.resume(returning: "Camera output unavailable.")
                    return
                }
                self.session.addOutput(self.photoOutput)
                // Prioritize quality — these stills go on the pro's profile + the
                // Looks feed, so favor the best capture over speed.
                self.photoOutput.maxPhotoQualityPrioritization = .quality

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
            let cont = self.captureContinuation
            self.captureContinuation = nil
            if let error {
                cont?.resume(throwing: error)
            } else if let bytes {
                cont?.resume(returning: bytes)
            } else {
                cont?.resume(throwing: CameraError.noData)
            }
        }
    }
}
