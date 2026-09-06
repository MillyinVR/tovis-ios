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
    /// On-device expectations per server-owned slot; no client trait is derived
    /// or stored. A key this build does not know (a pack added after it
    /// shipped) gets the neutral expectations: any framing, face optional, so
    /// the slot still captures rather than blocking the consult.
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
        case .areaWide:
            // The treatment area in context — hands, a brow line, a patch of
            // skin. No face required; a wide framing band.
            return ShotExpectations(
                face: .either,
                fillBand: 0.2...0.95,
                isDetail: false,
                allowsClosedEyes: true
            )
        case .areaCloseup:
            return ShotExpectations(
                face: .either,
                fillBand: nil,
                isDetail: true,
                allowsClosedEyes: true
            )
        default:
            return ShotExpectations(
                face: .either,
                fillBand: nil,
                isDetail: false,
                allowsClosedEyes: true
            )
        }
    }

    /// A line for a shot the client cannot reasonably take by herself.
    ///
    /// The consult's premise is a client alone in bed with her phone, and the
    /// hair pack asks her for the back of her own head. Pretending that is an
    /// ordinary framing problem is what makes an app feel like it is not on your
    /// side, so this says the true thing instead — including that she can just
    /// not do it. She can: partial capture is the norm, and the thread already
    /// offers "continue with N of M" once one shot is accepted
    /// (`canOfferPartialContinue`), so this promises nothing that is not built.
    ///
    /// Only `hair_back` gets one. The crown is awkward but reachable with the
    /// rear camera held overhead; the sides are reachable in a mirror. The back
    /// is the one that genuinely needs someone else.
    static func helperLine(
        for key: ConsultCaptureShotKey
    ) -> (title: String, detail: String)? {
        guard key == .hairBack else { return nil }
        return (
            title: "This one’s tricky solo",
            detail: "Have someone take this one, or skip it for now."
        )
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
    /// Decide the crop (P3) and produce the bytes to upload.
    func prepare(
        _ source: Data, for shot: ConsultCaptureShot
    ) async -> ConsultPreparedPhoto?
}

nonisolated struct NativeConsultJPEGPreparation: ConsultJPEGPreparing {
    func prepare(
        _ source: Data, for shot: ConsultCaptureShot
    ) async -> ConsultPreparedPhoto? {
        let plan = await ConsultPhotoPreparation.plan(source, for: shot)
        return await ConsultPhotoPreparation.prepare(source, plan: plan)
    }
}

nonisolated enum ConsultPhotoCandidateOutcome: Sendable, Equatable {
    case accepted(ConsultPreparedPhoto)
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

    /// Judge a captured still and produce the bytes to upload.
    ///
    /// 🔴 QC runs on the FULL frame, BEFORE the crop, and the order is
    /// load-bearing. `PhotoQC` finds a face with `CIDetector` to read blink and
    /// to meter sharpness on the subject — and an `eyes_closeup` crop is a strip
    /// with no detectable face in it. Cropping first would therefore silently
    /// switch off blink detection on the one shot whose acceptance rule is
    /// "both OPEN eyes", and hand back a whole-strip sharpness instead of a
    /// face-region one. Measure the photograph; then cut it.
    func process(_ source: Data,
                 shot: ConsultCaptureShot,
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
        guard let prepared = await preparation.prepare(source, for: shot),
              !prepared.upload.isEmpty else {
            return .invalid
        }
        guard !Task.isCancelled else { return .cancelled }
        return .accepted(prepared)
    }

    func discard() { candidate = nil }

    /// Test-only visibility into the privacy invariant; no bytes leave here.
    func retainedByteCount() -> Int { candidate?.count ?? 0 }
}

// MARK: - Native guided capture surface

struct ConsultGuidedCaptureView: View {
    @Environment(\.dismiss) private var dismiss

    let shot: ConsultCaptureShot
    /// The RAW still, handed straight out.
    ///
    /// 🔴 P3 moved quality checking, cropping and encoding OUT of this view and
    /// behind this closure, into the flow model that owns the durable queue.
    /// The camera's whole job is now: take a photograph, hand it over, leave.
    /// It cannot show a verdict because by the time there is one it is gone —
    /// which is the point. The verdict lands on the checklist row.
    let onStill: (Data) async -> Void

    @State private var camera = CameraController()
    @State private var coach: CoachEngine?
    @State private var machine = ConsultGuidedCaptureMachine()
    @State private var pickerItem: PhotosPickerItem?
    @State private var captureTask: Task<Void, Never>?
    @State private var fallbackBusy = false
    /// Which camera is live. Seeded from what the client chose LAST time for
    /// this shot, else the policy default (`ConsultCaptureCrop.defaultCamera`).
    @State private var position: ConsultCameraPosition = .front
    @State private var flipping = false
    /// A camera-hardware failure to tell the client about, while the shutter
    /// stays live.
    ///
    /// 🔴 Not the machine's `.localRetake` phase. Going straight back to
    /// `.ready` (so the shutter IS the retry, with no button) also leaves that
    /// phase instantly, so its card renders for zero frames — a shutter press
    /// that produced neither a photograph nor a word, which is the exact
    /// failure this whole chain exists to remove. This outlives the transition.
    @State private var cameraNotice: String?

    private var expectations: ShotExpectations {
        ConsultShotGuidance.expectations(for: shot.key)
    }

    /// The box the client composes inside for a tight-crop shot. Nil for
    /// FULL_VIEW, which is composed and uploaded as framed.
    private var guideBox: CGRect? { ConsultCaptureCrop.guideBox(for: shot) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.status == .ready || camera.status == .interrupted {
                CameraPreview(session: camera.session) { camera.previewLayer = $0 }
                    .ignoresSafeArea()
                    .overlay(Color.black.opacity(camera.status == .interrupted ? 0.62 : 0))
                    .overlay { guideBoxOverlay }
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
            let opening = ConsultCameraMemory.camera(for: shot.key)
            position = opening
            let engine = CoachEngine(runtimeOptions: .visualOnly)
            coach = engine
            engine.start()
            engine.analyzer.setExpectations(expectations)
            // The coach judges composition inside the guide box on a tight-crop
            // shot, for the same reason the pro camera judges inside the publish
            // crop: what is outside it is not what gets uploaded.
            engine.analyzer.setCropGuide(guideBox)
            engine.onFaceCenter = { [weak camera = camera] center in
                camera?.setFaceExposure(
                    center: expectations.face == .absent ? nil : center
                )
            }
            await camera.start(
                frameDelegate: engine.analyzer,
                position: opening == .front ? .front : .back
            )
            syncCoachOrientation()
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
            if let cameraNotice {
                guidanceCard(icon: "exclamationmark.triangle.fill",
                             title: "That one didn’t take", detail: cameraNotice)
            } else if let nudge = coach?.nudge {
                guidanceCard(icon: "viewfinder", title: nudge.message,
                             detail: "Adjust until the ring turns green.")
            } else if let helper = ConsultShotGuidance.helperLine(for: shot.key) {
                // Below the coach's nudge, not above it. The line says "have
                // someone take this one" — and whoever IS holding the phone
                // still needs to hear "it's too dark". It replaces the GENERIC
                // filler card below, which is the one that has nothing to say.
                guidanceCard(icon: "person.2.fill", title: helper.title,
                             detail: helper.detail)
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
            guidanceCard(icon: "camera.fill", title: "Got it",
                         detail: "Taking you back to your list.")
        case let .localRetake(reason):
            // Camera FAILURE only — never a quality verdict. Quality is judged
            // after this screen has gone and lands on the checklist row.
            guidanceCard(icon: "exclamationmark.triangle.fill",
                         title: "That one didn’t take", detail: reason)
        case .delivered:
            guidanceCard(icon: "checkmark.circle.fill", title: "Got it",
                         detail: "Taking you back to your list.")
        case .cancelled:
            EmptyView()
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            // 🔴 No retry button in ANY state (P3). A camera failure returns
            // straight to `.ready` — the shutter is right there and is the retry
            // — and a quality refusal is not this screen's news to give.
            if machine.phase == .ready {
                HStack(spacing: 22) {
                    flipButton
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
                    // Balances the flip button so the shutter stays centred.
                    Color.clear.frame(width: 52, height: 52)
                }
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

    private var flipButton: some View {
        Button {
            captureTask = Task { await flipCamera() }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.black.opacity(0.52), in: Circle())
        }
        .disabled(flipping || captureTask != nil)
        .accessibilityLabel(
            position == .front ? "Switch to the rear camera" : "Switch to the front camera"
        )
    }

    /// The box the client composes inside on a tight-crop shot.
    ///
    /// It is drawn through the same mapper the pro camera's publish-crop rails
    /// use (`CameraPreviewGeometry`), so what is inside the lines is what the
    /// preview is actually showing — under `.resizeAspectFill` a proportional
    /// rect would not be.
    @ViewBuilder
    private var guideBoxOverlay: some View {
        if let guideBox {
            GeometryReader { geo in
                let box = CameraPreviewGeometry.previewRect(
                    uprightNormalized: guideBox, in: geo.size, layer: camera.previewLayer
                )
                Rectangle()
                    .strokeBorder(.white.opacity(0.62), lineWidth: 1.5)
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var visionExpectationCopy: String {
        switch expectations.face {
        case .required: return "Keep the face visible along with the requested view."
        case .absent: return "Fill the frame with the requested view; a face isn’t required."
        case .either: return "Fill the frame with the requested view."
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

    /// Shutter → photograph → gone.
    ///
    /// 🔴 The ONLY thing between the shutter and `dismiss()` is AVFoundation
    /// delivering the frame. No quality check, no crop, no encode, no preview,
    /// no confirm (P3). Those all happen behind `onStill`, in the flow model
    /// that owns the durable queue, and their verdict appears on the checklist
    /// row the client is already looking at by then.
    ///
    /// `onStill` is deliberately NOT awaited before dismissing, and is launched
    /// as a detached task rather than left on `captureTask`: once the shutter
    /// has fired the shot is OWED, and nothing about this view going away is
    /// allowed to be the reason it does not arrive.
    private func capture() async {
        cameraNotice = nil
        machine.beginCapture()
        do {
            let source = try await camera.capturePhoto()
            handOff(source)
            machine.delivered()
            dismiss()
        } catch {
            // A failure here is a real camera failure — nothing cancels this
            // task. It gets a line either way: a shutter press that produces
            // neither a photograph nor a word is the failure this whole chain
            // exists to remove.
            ConsultCaptureTelemetry.queue(
                "camera_capture_failed shot=\(shot.key.rawValue) cancelled=\(Task.isCancelled)",
                level: .error
            )
            cameraNotice = "The camera didn’t finish that one — the shutter is ready when you are."
            machine.requestRetake(cameraNotice ?? "")
            // Straight back to a live shutter: the retry IS the shutter, so
            // there is no button to press to get one. The notice above is what
            // keeps the failure on screen across that transition.
            machine.retry()
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
        handOff(source)
        machine.delivered()
        dismiss()
    }

    /// Hand the still to the flow model, outside this view's lifetime.
    private func handOff(_ source: Data) {
        let deliver = onStill
        Task.detached(priority: .userInitiated) { await deliver(source) }
    }

    /// Swap cameras and re-point the coach at the new frame geometry.
    ///
    /// 🔴 `syncCoachOrientation` is not optional housekeeping. The analyzer
    /// orients every buffer it reads, and the two cameras need different
    /// corrections; leaving it on the old value after a flip means Vision reads
    /// an upside-down, mirrored frame, finds no face, and the coach quietly
    /// stops working — with a green-looking UI and nothing in the log.
    private func flipCamera() async {
        flipping = true
        defer { flipping = false; captureTask = nil }
        let settled = await camera.flip()
        let now: ConsultCameraPosition = settled == .front ? .front : .rear
        syncCoachOrientation()
        guard now != position else { return }   // no camera on that side
        position = now
        ConsultCameraMemory.remember(now, for: shot.key)
    }

    private func syncCoachOrientation() {
        coach?.analyzer.setSourceOrientation(
            CameraController.sourceOrientation(for: camera.cameraPosition)
        )
    }

    /// Close the camera. It does NOT cancel a capture already under way — see
    /// `handOff`. Backing out before pressing the shutter takes nothing with it;
    /// backing out after is not a way to un-take a photograph.
    private func cancel() {
        if machine.phase != .capturing { machine.cancel() }
        dismiss()
    }

    /// Stop the hardware. The capture task is deliberately left running.
    ///
    /// 🔴 This used to `captureTask?.cancel()` and `pipeline.discard()`, which is
    /// precisely the prod failure: `.onDisappear` fires the instant the sheet
    /// begins dismissing, so a shot taken and then dismissed was cancelled
    /// mid-chain and vanished. The coach is this view's to stop; the photograph
    /// is not this view's to drop.
    ///
    /// ⚠️ And the camera is stopped only AFTER any in-flight capture finishes.
    /// `CameraController.stop()` calls `stopRunning()` on the session, which
    /// aborts a photo AVFoundation has not delivered yet — so stopping it here
    /// unconditionally would have re-created the same lost shot through a
    /// different door, after the cancellation was removed. `pending` is nil in
    /// the ordinary case and this is then the same immediate stop it always was.
    private func tearDown() {
        coach?.stop()
        let pending = captureTask
        if pending != nil {
            ConsultCaptureTelemetry.queue("view_dismissed_mid_capture shot=\(shot.key.rawValue)")
        }
        let controller = camera
        Task {
            await pending?.value
            controller.stop()
        }
    }
}
