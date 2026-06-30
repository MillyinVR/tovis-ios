// A minimal custom camera over AVFoundation: live preview + still capture → JPEG.
//
// Built custom (not the system PhotosPicker) on purpose: Phase B of the "AI
// photographer" taps the live frame buffer for the on-device coach (lighting /
// composition / background / pose) and draws overlays on the preview. For Phase A
// this is capture-only; the AVCaptureVideoDataOutput coaching hook lands in B.
import AVFoundation
import SwiftUI

enum CameraError: Error { case noData }

@Observable
@MainActor
final class CameraController: NSObject {
    enum Status: Equatable { case idle, configuring, ready, denied, failed(String) }

    private(set) var status: Status = .idle

    // The AVFoundation objects are confined to `sessionQueue`. They're marked
    // nonisolated(unsafe) so the queue closures can touch them without tripping
    // the project's default-MainActor isolation — the serial queue is the real
    // guard. `session` is read by CameraPreview (nonisolated → safe to read).
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) private let videoOutput = AVCaptureVideoDataOutput()
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
    private let sessionQueue = DispatchQueue(label: "tovis.camera.session")
    private let frameQueue = DispatchQueue(label: "tovis.camera.frames")

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
                self.captureContinuation = cont
                // Force JPEG so the bytes match the "image/jpeg" content-type we
                // presign with (the device default can be HEIC).
                let settings: AVCapturePhotoSettings
                if self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
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

                guard self.session.canAddOutput(self.photoOutput) else {
                    self.session.commitConfiguration()
                    cont.resume(returning: "Camera output unavailable.")
                    return
                }
                self.session.addOutput(self.photoOutput)

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

                self.session.commitConfiguration()
                cont.resume(returning: nil)
            }
        }
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
