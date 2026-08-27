import PhotosUI
import SwiftUI
import TovisKit

// MARK: - Framework-agnostic capture contract

nonisolated enum ConsultGuidedCameraAvailability: Sendable, Equatable {
    case starting
    case ready
    case interrupted
    case fallback

    init(cameraStatus: CameraController.Status) {
        switch cameraStatus {
        case .idle, .configuring: self = .starting
        case .ready: self = .ready
        case .interrupted: self = .interrupted
        case .denied, .failed: self = .fallback
        }
    }
}

nonisolated enum ConsultGuidedCapturePhase: Sendable, Equatable {
    case waiting
    case ready
    case interrupted
    case fallback
    case capturing
    case localRetake(String)
    case delivered
    case cancelled
}

/// Content-free state reducer for authorization, interruption, retry, and
/// cancellation. It never owns a frame, JPEG, path, token, or observation.
nonisolated struct ConsultGuidedCaptureMachine: Sendable, Equatable {
    private(set) var phase: ConsultGuidedCapturePhase = .waiting

    mutating func cameraChanged(_ availability: ConsultGuidedCameraAvailability) {
        guard phase != .cancelled, phase != .delivered else { return }
        switch availability {
        case .starting: phase = .waiting
        case .ready: phase = .ready
        case .interrupted: phase = .interrupted
        case .fallback: phase = .fallback
        }
    }

    mutating func beginCapture() {
        guard phase == .ready else { return }
        phase = .capturing
    }

    mutating func requestRetake(_ reason: String) {
        guard phase == .capturing else { return }
        phase = .localRetake(reason)
    }

    mutating func retry() {
        guard case .localRetake = phase else { return }
        phase = .ready
    }

    mutating func delivered() {
        guard phase == .capturing else { return }
        phase = .delivered
    }

    mutating func cancel() { phase = .cancelled }
}

nonisolated enum ConsultShotGuidance {
    /// The seven server-owned pack-v2 slots keep their identity and order. Only
    /// their on-device expectations live here; no client trait is derived or
    /// stored.
    static func expectations(for key: ConsultCaptureShotKey) -> ShotExpectations {
        switch key {
        case .hairBack:
            return ShotExpectations(
                face: .absent,
                fillBand: 0.22...0.9,
                isDetail: false,
                allowsClosedEyes: true
            )
        case .hairLeft, .hairRight:
            return ShotExpectations(
                face: .required,
                fillBand: 0.28...0.9,
                isDetail: false,
                allowsClosedEyes: true
            )
        case .hairCrown:
            return ShotExpectations(
                face: .absent,
                fillBand: 0.3...0.95,
                isDetail: true,
                allowsClosedEyes: true
            )
        case .faceFront:
            // Straight-on portrait with open eyes: undertone/contrast/geometry
            // read from this view, so framing wants the classic portrait band.
            return ShotExpectations(
                face: .required,
                fillBand: 0.22...0.85,
                isDetail: false
            )
        case .faceSide:
            // Full profile; Vision face detection handles profiles the same way
            // it already does for the hair side views.
            return ShotExpectations(
                face: .required,
                fillBand: 0.25...0.9,
                isDetail: false
            )
        case .eyesCloseup:
            // Macro of both open eyes and brows: sharpness matters, a full face
            // may not be detectable in frame.
            return ShotExpectations(
                face: .either,
                fillBand: nil,
                isDetail: true
            )
        }
    }

}

nonisolated protocol ConsultPhotoQCEvaluating: Sendable {
    func evaluate(_ jpeg: Data, checkBlink: Bool) async -> PhotoQCReport
}

nonisolated struct NativeConsultPhotoQC: ConsultPhotoQCEvaluating {
    func evaluate(_ jpeg: Data, checkBlink: Bool) async -> PhotoQCReport {
        await PhotoQC.evaluate(jpeg, checkBlink: checkBlink)
    }
}

nonisolated protocol ConsultJPEGPreparing: Sendable {
    func prepare(_ source: Data) async -> Data?
}

nonisolated struct NativeConsultJPEGPreparation: ConsultJPEGPreparing {
    func prepare(_ source: Data) async -> Data? {
        await ConsultPhotoPreparation.jpeg(from: source)
    }
}

nonisolated enum ConsultPhotoCandidateOutcome: Sendable, Equatable {
    case accepted(Data)
    case retake(String)
    case invalid
    case cancelled
}

/// The one transient-byte owner between shutter/picker and C8's private upload.
/// A `defer` clears its candidate on every success, failure, or cancellation;
/// it has no filesystem or Photos-library API and never sees an upload token.
actor ConsultTransientPhotoPipeline {
    private let quality: any ConsultPhotoQCEvaluating
    private let preparation: any ConsultJPEGPreparing
    private var candidate: Data?

    init(quality: any ConsultPhotoQCEvaluating = NativeConsultPhotoQC(),
         preparation: any ConsultJPEGPreparing = NativeConsultJPEGPreparation()) {
        self.quality = quality
        self.preparation = preparation
    }

    func process(_ source: Data,
                 expectations: ShotExpectations) async -> ConsultPhotoCandidateOutcome {
        candidate = source
        defer { candidate = nil }
        guard !Task.isCancelled else { return .cancelled }

        let report = await quality.evaluate(
            source,
            checkBlink: !expectations.allowsClosedEyes
        )
        guard !Task.isCancelled else { return .cancelled }
        guard report.passed else {
            return .retake(report.retakeReason ?? "That photo needs another try.")
        }
        guard let jpeg = await preparation.prepare(source), !jpeg.isEmpty else {
            return .invalid
        }
        guard !Task.isCancelled else { return .cancelled }
        return .accepted(jpeg)
    }

    func discard() { candidate = nil }

    /// Test-only visibility into the privacy invariant; no bytes leave here.
    func retainedByteCount() -> Int { candidate?.count ?? 0 }
}

// MARK: - Native guided capture surface

struct ConsultGuidedCaptureView: View {
    @Environment(\.dismiss) private var dismiss

    let shot: ConsultCaptureShot
    let onJPEG: (Data) async -> Void

    @State private var camera = CameraController()
    @State private var coach: CoachEngine?
    @State private var machine = ConsultGuidedCaptureMachine()
    @State private var pickerItem: PhotosPickerItem?
    @State private var captureTask: Task<Void, Never>?
    @State private var fallbackBusy = false

    @State private var pipeline = ConsultTransientPhotoPipeline()

    private var expectations: ShotExpectations {
        ConsultShotGuidance.expectations(for: shot.key)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.status == .ready || camera.status == .interrupted {
                CameraPreview(session: camera.session) { camera.previewLayer = $0 }
                    .ignoresSafeArea()
                    .overlay(Color.black.opacity(camera.status == .interrupted ? 0.62 : 0))
            }

            VStack(spacing: 0) {
                header
                Spacer()
                statusPanel
                controls
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .task {
            let engine = CoachEngine(runtimeOptions: .visualOnly)
            coach = engine
            engine.start()
            engine.analyzer.setExpectations(expectations)
            engine.analyzer.setCropGuide(nil)
            engine.onFaceCenter = { [weak camera = camera] center in
                camera?.setFaceExposure(
                    center: expectations.face == .absent ? nil : center
                )
            }
            await camera.start(frameDelegate: engine.analyzer)
            apply(camera.status)
        }
        .onChange(of: camera.status) { _, status in apply(status) }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            captureTask = Task { await usePickerItem(item) }
        }
        .onDisappear { tearDown() }
        .tint(BrandColor.accent)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shot.title)
                    .font(BrandFont.display(24, .semibold))
                    .foregroundStyle(.white)
                Text(shot.instruction)
                    .font(BrandFont.body(13))
                    .foregroundStyle(.white.opacity(0.78))
            }
            Spacer()
            Button { cancel() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.48), in: Circle())
            }
            .accessibilityLabel("Cancel guided capture")
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var statusPanel: some View {
        switch machine.phase {
        case .waiting:
            guidanceCard(icon: "camera.fill", title: "Starting camera…",
                         detail: "Camera frames stay on this device.")
        case .ready:
            if let nudge = coach?.nudge {
                guidanceCard(icon: "viewfinder", title: nudge.message,
                             detail: "Adjust until the ring turns green.")
            } else {
                guidanceCard(
                    icon: coach?.isReady == true ? "checkmark.circle.fill" : "viewfinder",
                    title: coach?.isReady == true ? "Hold steady" : "Frame this view",
                    detail: visionExpectationCopy
                )
            }
        case .interrupted:
            guidanceCard(icon: "pause.circle.fill", title: "Camera paused",
                         detail: "Finish the interruption to resume, or choose a photo below.")
        case .fallback:
            guidanceCard(icon: "photo.on.rectangle", title: "Use your photo library",
                         detail: "Camera access isn’t available. You can still finish this slot with the system photo picker.")
        case .capturing:
            guidanceCard(icon: "hourglass", title: "Checking the photo…",
                         detail: "Only this chosen JPEG can continue to the private upload.")
        case let .localRetake(reason):
            guidanceCard(icon: "arrow.clockwise.circle.fill", title: "Take one more",
                         detail: reason)
        case .delivered:
            guidanceCard(icon: "checkmark.circle.fill", title: "Photo sent for quality review",
                         detail: "The server still makes the final quality decision.")
        case .cancelled:
            EmptyView()
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if case .localRetake = machine.phase, camera.status == .ready {
                Button("Retake with guidance") { machine.retry() }
                    .buttonStyle(ConsultCameraPrimaryButtonStyle())
            } else if machine.phase == .ready {
                Button { captureTask = Task { await capture() } } label: {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.45), lineWidth: 5)
                            .frame(width: 82, height: 82)
                        Circle()
                            .trim(from: 0, to: max(0.04, coach?.readiness ?? 0.04))
                            .stroke(coach?.isReady == true ? BrandColor.emerald : BrandColor.amber,
                                    style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 82, height: 82)
                        Circle().fill(.white).frame(width: 62, height: 62)
                    }
                }
                .disabled(captureTask != nil)
                .accessibilityLabel("Take " + shot.title + " photo")
            }

            if machine.phase != .capturing, machine.phase != .delivered {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label(fallbackBusy ? "Checking photo…" : "Choose from Photos instead",
                          systemImage: "photo.on.rectangle")
                        .font(BrandFont.body(14, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(.black.opacity(0.52), in: Capsule())
                }
                .disabled(fallbackBusy || captureTask != nil)
            }
        }
        .padding(.top, 14)
    }

    private var visionExpectationCopy: String {
        switch expectations.face {
        case .required: return "Keep the side of the face and the full hair view visible."
        case .absent: return "Fill the frame with the hair; a face isn’t required for this view."
        case .either: return "Fill the frame with the requested hair view."
        }
    }

    private func guidanceCard(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BrandColor.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(BrandFont.body(15, .semibold)).foregroundStyle(.white)
                Text(detail).font(BrandFont.body(12)).foregroundStyle(.white.opacity(0.72))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 16))
    }

    private func apply(_ status: CameraController.Status) {
        machine.cameraChanged(ConsultGuidedCameraAvailability(cameraStatus: status))
    }

    private func capture() async {
        machine.beginCapture()
        do {
            let source = try await camera.capturePhoto()
            await finish(source)
        } catch {
            guard !Task.isCancelled else { return }
            machine.requestRetake("The camera didn’t finish that photo. Please try again.")
        }
        captureTask = nil
    }

    private func usePickerItem(_ item: PhotosPickerItem) async {
        fallbackBusy = true
        defer {
            fallbackBusy = false
            pickerItem = nil
            captureTask = nil
        }
        guard let source = try? await item.loadTransferable(type: Data.self) else {
            machine.cameraChanged(.fallback)
            return
        }
        if machine.phase != .ready { machine.cameraChanged(.ready) }
        machine.beginCapture()
        await finish(source)
    }

    private func finish(_ source: Data) async {
        switch await pipeline.process(source, expectations: expectations) {
        case let .accepted(jpeg):
            guard !Task.isCancelled, machine.phase != .cancelled else { return }
            await onJPEG(jpeg)
            machine.delivered()
            dismiss()
        case let .retake(reason):
            machine.requestRetake(reason)
        case .invalid:
            machine.requestRetake("That image couldn’t be prepared as a private JPEG. Try another photo.")
        case .cancelled:
            break
        }
    }

    private func cancel() {
        machine.cancel()
        captureTask?.cancel()
        captureTask = nil
        Task { await pipeline.discard() }
        dismiss()
    }

    private func tearDown() {
        camera.stop()
        coach?.stop()
        captureTask?.cancel()
        captureTask = nil
        Task { await pipeline.discard() }
    }
}

private struct ConsultCameraPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandFont.body(15, .semibold))
            .foregroundStyle(BrandColor.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(BrandColor.accent.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
