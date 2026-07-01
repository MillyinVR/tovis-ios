// Pro session photo capture — the custom camera for BEFORE/AFTER session photos.
// Phase A: live preview + shutter → upload (presign→PUT→confirm) + a strip of
// what you've shot this session. The on-device AI coach (overlays, readiness
// ring, pose templates) layers onto this preview in Phase B.
import AVFoundation
import SwiftUI
import TovisKit

struct ProCapturePhotosView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let bookingId: String
    let phase: MediaPhase
    /// Base service name (e.g. "Balayage") — selects the ShotGuide. Nil → generic.
    var serviceName: String? = nil
    /// "Before" photos to ghost as onion-skin while shooting AFTER, so the pairs
    /// line up. Empty for the BEFORE phase (nothing to match yet).
    var referenceURLs: [URL] = []

    @State private var camera = CameraController()
    /// Onion-skin (before/after matching) state.
    @State private var onionEnabled = true
    @State private var onionOpacity: Double = 0.35
    @State private var referenceIndex = 0
    /// The directed shot list for this service + progress through it.
    @State private var guide: ShotGuide = .generic
    @State private var currentStepID: String?
    @State private var completedStepIDs: Set<String> = []
    /// Tap-to-focus reticle position (preview space) + a token to time its fade.
    @State private var focusPoint: CGPoint?
    @State private var focusToken = 0
    /// Guided auto-capture is armed (fires once per stabilization — must drop out
    /// of "ready" and settle again before the next auto-shot).
    @State private var autoArmed = true
    /// Showing the white-balance calibration target (fill it with a neutral surface).
    @State private var calibrating = false
    /// Local thumbnails of shots taken this session (newest first) — shown
    /// instantly from the captured bytes, no network round-trip.
    @State private var captured: [CapturedShot] = []
    /// Captured JPEGs whose upload failed — kept for retry so a flaky connection
    /// never loses a shot the pro already took.
    @State private var failedUploads: [Data] = []
    @State private var uploading = false
    @State private var errorMessage: String?

    private struct CapturedShot: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    /// A manual shot the photographer check flagged — held for the pro's
    /// keep-or-retake call instead of silently entering the portfolio.
    @State private var pendingRetake: PendingRetake?
    private struct PendingRetake: Identifiable {
        let id = UUID()
        let data: Data
        let reason: String
    }

    /// Measured light (luma + warmth) of each "before" reference — the target
    /// the AFTER shoot matches so the transformation compare is credible
    /// (same angle via onion-skin, same LIGHT via this).
    @State private var referenceLight: [URL: LightStamp] = [:]
    private struct LightStamp: Equatable { let luma: Double; let warmth: Double }
    /// Brief white flash on a successful capture (shutter confirmation).
    @State private var flash = false

    // AI photographer (Phase B1): live coach + how-it-guides toggles.
    @State private var settings = CoachSettings()
    @State private var coach: CoachEngine?
    @State private var showSettings = false
    /// DEBUG tuning console (rides over the live camera; not a reviewing state).
    @State private var showTuning = false
    @State private var showBestShots = false
    /// Guards exit while the coach has auto-harvested best shots the pro hasn't
    /// reviewed yet — otherwise tapping Done silently discards them.
    @State private var showExitConfirm = false
    /// A just-recorded clip awaiting frame-by-frame review (nil = none).
    @State private var scrubClip: ScrubClip?

    private struct ScrubClip: Identifiable, Equatable { let url: URL; var id: String { url.absoluteString } }

    /// True while a selection/review surface is up (best-shots tray, frame
    /// scrubber, or settings) — the live camera pauses so it isn't still
    /// capturing + auto-harvesting while the pro picks photos.
    private var isReviewing: Bool { showBestShots || showSettings || scrubClip != nil }

    /// The coach reads the frame as good-to-shoot (green ring).
    private var isReady: Bool { coach?.isReady ?? false }

    /// Onion-skin is on, and there's a "before" to ghost (AFTER phase only).
    private var showOnion: Bool { onionEnabled && !referenceURLs.isEmpty }
    private var currentReferenceURL: URL? {
        guard !referenceURLs.isEmpty else { return nil }
        return referenceURLs[min(max(referenceIndex, 0), referenceURLs.count - 1)]
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.status {
            case .denied:
                permissionState
            case let .failed(message):
                failedState(message)
            default:
                cameraUI
            }

            if flash {
                Color.white.ignoresSafeArea().transition(.opacity)
            }
        }
        .task {
            guide = ShotGuide.resolve(forServiceNamed: serviceName)
            if currentStepID == nil { currentStepID = guide.steps.first?.id }
            let engine = coach ?? CoachEngine(settings: settings)
            coach = engine
            // Re-arm CoreMotion: the frame scrubber is a fullScreenCover, which
            // fires this view's onDisappear → engine.stop(); on return the
            // engine is reused, so the level stream must be restarted here or
            // the horizon (and LevelCoach) freeze at stale tilt.
            engine.start()
            // The photographer meters for the face: feed the coach's face
            // detection into exposure so "too dark"/"backlit" fix themselves.
            engine.onFaceCenter = { [weak camera = camera] center in
                camera?.setFaceExposure(center: center)
            }
            engine.analyzer.setExpectations(activeExpectations)
            // Persist gray-card WB per booking: the AFTER shoot re-applies the
            // BEFORE's calibration automatically (one card, one session).
            camera.onWhiteBalanceLocked = { r, g, b in
                UserDefaults.standard.set([r, g, b], forKey: wbDefaultsKey)
            }
            await camera.start(frameDelegate: engine.analyzer)
            if !camera.whiteBalanceCalibrated,
               let gains = UserDefaults.standard.array(forKey: wbDefaultsKey) as? [Double],
               gains.count == 3 {
                camera.applyWhiteBalanceGains(r: gains[0], g: gains[1], b: gains[2])
            }
            // Stamp each "before" reference's light so the AFTER can match it.
            if referenceLight.isEmpty, !referenceURLs.isEmpty {
                await loadReferenceLight()
            }
        }
        // Keep the coach judging "ready for THIS shot" — expectations follow the
        // current guided step (and clear for freeform / all-done shooting).
        .onChange(of: activeExpectations) { _, expectations in
            coach?.analyzer.setExpectations(expectations)
        }
        .onDisappear { camera.stop(); coach?.stop() }
        // A recorded clip is one-shot: once its review closes (saved or not),
        // clear the temp file so tovis-clip-*.mov files don't pile up in tmp.
        .onChange(of: scrubClip) { old, new in
            if let old, new == nil { try? FileManager.default.removeItem(at: old.url) }
        }
        // Pause the live camera while the pro is reviewing/picking shots or in
        // settings — otherwise it keeps capturing, scoring, and auto-harvesting
        // behind the sheet. Resume when they return to shooting.
        .onChange(of: isReviewing) { _, reviewing in
            if reviewing {
                if camera.isRecording { Task { _ = try? await camera.stopRecording() } }
                camera.stop()
            } else {
                camera.resume()
            }
        }
        // Ghost the "before" that matches the current guided shot (before/after
        // were shot in the same order), so the pair lines up. Manual cycle overrides.
        .onChange(of: currentStepID) {
            if !referenceURLs.isEmpty {
                referenceIndex = min(currentStepIndex, referenceURLs.count - 1)
            }
            // The photographer calls the next shot.
            if settings.speak, !allStepsDone, let step = currentStep {
                coach?.announce("Next, the \(step.title). \(step.hint)")
            }
        }
        // Guided auto-capture: re-arm when the shot drops out of "ready", and shoot
        // once it has held good + steady (isSteadyReady) while armed.
        .onChange(of: coach?.isReady ?? false) { _, ready in
            if !ready { autoArmed = true }
        }
        .onChange(of: coach?.isSteadyReady ?? false) { _, steady in
            if steady, autoArmed { attemptGuidedCapture() }
        }
        .sheet(isPresented: $showSettings) {
            #if DEBUG
            CoachSettingsSheet(settings: settings, onOpenTuning: { showTuning = true })
            #else
            CoachSettingsSheet(settings: settings)
            #endif
        }
        #if DEBUG
        // The tuning console rides a half-height sheet over the LIVE camera —
        // preview on top, sliders below, signals streaming (not in isReviewing).
        .sheet(isPresented: $showTuning) {
            if let coach {
                CoachTuningHUD(coach: coach)
                    .presentationDetents([.fraction(0.45), .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .large))
            }
        }
        #endif
        .sheet(isPresented: $showBestShots) {
            if let coach {
                BestShotsReviewView(coach: coach, bookingId: bookingId, phase: phase)
            }
        }
        .fullScreenCover(item: $scrubClip) { clip in
            FrameScrubberView(videoURL: clip.url, bookingId: bookingId, phase: phase)
        }
        .modifier(RetakeDialog(pendingRetake: $pendingRetake, keep: { data in
            Task {
                uploading = true
                await finalize(data)
                uploading = false
            }
        }))
        .confirmationDialog(
            "You have unsaved best shots",
            isPresented: $showExitConfirm,
            titleVisibility: .visible
        ) {
            Button("Review best shots") { showBestShots = true }
            Button("Discard & exit", role: .destructive) { dismiss() }
            Button("Keep shooting", role: .cancel) {}
        } message: {
            Text("The camera captured \(coach?.harvested.count ?? 0) best shots this session. Review them to save to \(phaseLabel) — leaving now discards them.")
        }
    }

    /// The photographer-check keep-or-retake dialog, extracted as a modifier —
    /// inlining it pushed the body's modifier chain past what the type-checker
    /// resolves in reasonable time.
    private struct RetakeDialog: ViewModifier {
        @Binding var pendingRetake: PendingRetake?
        let keep: (Data) -> Void

        func body(content: Content) -> some View {
            content.confirmationDialog(
                "Photographer check",
                isPresented: Binding(
                    get: { pendingRetake != nil },
                    set: { if !$0 { pendingRetake = nil } }   // dismiss = retake
                ),
                titleVisibility: .visible,
                presenting: pendingRetake
            ) { shot in
                Button("Retake") { pendingRetake = nil }
                Button("Keep it anyway") {
                    let data = shot.data
                    pendingRetake = nil
                    keep(data)
                }
            } message: { shot in
                Text("\(shot.reason). Retake it while they’re still in position?")
            }
        }
    }

    /// Leave the camera — but if the coach is holding unreviewed best shots, ask
    /// first so they're not silently lost. Manually captured photos already
    /// uploaded, so only the harvest tray is at risk.
    private func requestExit() {
        if (coach?.harvested.isEmpty == false) {
            showExitConfirm = true
        } else {
            dismiss()
        }
    }

    // MARK: - Camera UI

    private var cameraUI: some View {
        VStack(spacing: 0) {
            // Live preview + coaching overlays
            ZStack(alignment: .top) {
                if camera.status == .ready {
                    CameraPreview(session: camera.session) { camera.previewLayer = $0 }
                        .ignoresSafeArea(edges: .top)
                        .overlay { focusReticleOverlay }
                        // Drawn as preview overlays so they share the preview
                        // layer's coordinate space (boxes map sensor regions
                        // exactly).
                        .overlay { if calibrating { calibrationTarget } }
                        .overlay { if settings.showCropGuide { cropSafeOverlay } }
                        .gesture(
                            SpatialTapGesture().onEnded { handleFocusTap($0.location) }
                        )
                } else {
                    Color.black
                    ProgressView().tint(.white)
                }

                if showOnion, let url = currentReferenceURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: { Color.clear }
                    .opacity(onionOpacity)
                    .allowsHitTesting(false)
                    .clipped()
                    .ignoresSafeArea(edges: .top)
                }

                if settings.showGrid { thirdsGrid }
                if settings.showLevel, let roll = coach?.deviceRoll { levelIndicator(roll) }

                VStack(spacing: 0) {
                    phaseHeader
                    if settings.showGuides, !guide.steps.isEmpty {
                        guideBar
                        guidanceBanner
                    }
                    if settings.showChecklist, let statuses = coach?.statuses, !statuses.isEmpty {
                        fundamentalsHUD(statuses)
                    }
                    // When not in guided mode, the single nudge chip stands in for
                    // the banner.
                    if (!settings.showGuides || guide.steps.isEmpty),
                       settings.showNudge, let message = coach?.nudge?.message {
                        nudgeChip(message)
                    }
                    Spacer()
                }
            }

            controls
        }
    }

    /// Rule-of-thirds guide.
    private var thirdsGrid: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width, h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(.white.opacity(0.25), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    // MARK: - White balance (gray-card calibration)

    /// The target the pro fills with a neutral surface — the EXACT region the
    /// analyzer samples for white balance (center 40% of the sensor frame),
    /// mapped through the preview layer's aspect-fill so the box on screen is
    /// the area being measured (an aspect-filled preview crops the sensor, so a
    /// naive "40% of the screen" box would under-show the sampled area).
    private var calibrationTarget: some View {
        GeometryReader { geo in
            let box = sampledRegionRect(in: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(BrandColor.gold, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .frame(width: box.width, height: box.height)
                Text("Fill this with a white towel or gray card")
                    .font(BrandFont.body(12, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .offset(y: -box.height / 2 - 24)
            }
            .position(x: box.midX, y: box.midY)
        }
        .allowsHitTesting(false)
    }

    /// Preview-space rect of the analyzer's white-balance sample region (the
    /// center 40% of the frame in both dimensions).
    private func sampledRegionRect(in size: CGSize) -> CGRect {
        previewRect(uprightNormalized: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), in: size)
    }

    /// Map a CENTERED upright-normalized frame rect into the preview layer's
    /// coordinate space (aspect-fill aware). Centered rects survive the
    /// upright→sensor rotation by swapping axes, so this stays exact without
    /// caring about the rotation direction. Falls back to a naive screen-space
    /// box before the layer has geometry.
    private func previewRect(uprightNormalized r: CGRect, in size: CGSize) -> CGRect {
        if let layer = camera.previewLayer, layer.bounds.width > 0 {
            let metadata = CGRect(x: r.minY, y: r.minX, width: r.height, height: r.width)
            return layer.layerRectConverted(fromMetadataOutputRect: metadata)
        }
        return CGRect(x: size.width * r.minX, y: size.height * r.minY,
                      width: size.width * r.width, height: size.height * r.height)
    }

    // MARK: - Crop-safe guide (publish crops)

    /// Publishing crops beauty work actually ships in: 4:5 (feed) and 9:16
    /// (reel/story). Drawn from the sensor frame through the preview layer so
    /// what's inside the lines is exactly what survives each crop — keep the
    /// money shot inside the tighter box.
    private var cropSafeOverlay: some View {
        GeometryReader { geo in
            ZStack {
                cropBox(aspect: 4.0 / 5.0, label: "4:5", in: geo.size)
                cropBox(aspect: 9.0 / 16.0, label: "9:16", in: geo.size)
            }
        }
        .allowsHitTesting(false)
    }

    /// A centered crop of `aspect` (w/h) within the upright 3:4 capture frame,
    /// mapped to preview space.
    private func cropBox(aspect: CGFloat, label: String, in size: CGSize) -> some View {
        let frameAspect: CGFloat = 3.0 / 4.0   // upright sensor frame w/h (.photo preset)
        let normalized: CGRect
        if aspect > frameAspect {
            // Wider than the frame → full width, cropped height.
            let h = frameAspect / aspect
            normalized = CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        } else {
            // Narrower → full height, cropped width.
            let w = aspect / frameAspect
            normalized = CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        }
        let box = previewRect(uprightNormalized: normalized, in: size)
        return Rectangle()
            .strokeBorder(.white.opacity(0.3), lineWidth: 1)
            .frame(width: box.width, height: box.height)
            .overlay(alignment: .topLeading) {
                Text(label)
                    .font(BrandFont.mono(9)).tracking(0.5)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.35), in: Capsule())
                    .padding(4)
            }
            .position(x: box.midX, y: box.midY)
    }

    /// The calibration action row (shown in the controls while calibrating).
    private var calibrationControls: some View {
        VStack(spacing: 8) {
            Text(camera.whiteBalanceCalibrated
                 ? "White balance locked — colors are true now"
                 : "Point at a neutral surface, then set")
                .font(BrandFont.body(12)).foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 10) {
                Button { setWhiteBalance() } label: {
                    Text("Set white balance").font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.onAccent)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(BrandColor.accent, in: Capsule())
                }
                if camera.whiteBalanceCalibrated {
                    Button {
                        camera.resetWhiteBalance()
                        UserDefaults.standard.removeObject(forKey: wbDefaultsKey)
                    } label: {
                        Text("Auto").font(BrandFont.body(14, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.white.opacity(0.14), in: Capsule())
                    }
                }
                Button { calibrating = false } label: {
                    Text("Done").font(BrandFont.body(14, .semibold)).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    /// Sample the center patch + lock white balance to neutralize the room's cast.
    private func setWhiteBalance() {
        let s = coach?.centerSample ?? (r: 0.5, g: 0.5, b: 0.5)
        camera.lockWhiteBalance(sampleR: s.r, sampleG: s.g, sampleB: s.b)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Tap to focus

    /// The focus/exposure reticle, drawn in the preview's coordinate space.
    @ViewBuilder private var focusReticleOverlay: some View {
        if let p = focusPoint {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(BrandColor.gold, lineWidth: 1.5)
                .frame(width: 74, height: 74)
                .position(p)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// Tap-to-focus: meter + focus on the tapped point (the work), show the reticle,
    /// fade it after a beat. Releases any AE/AF lock (handled in the controller).
    private func handleFocusTap(_ point: CGPoint) {
        camera.focus(atLayerPoint: point)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.12)) { focusPoint = point }
        focusToken += 1
        let token = focusToken
        Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            if focusToken == token { withAnimation(.easeIn(duration: 0.3)) { focusPoint = nil } }
        }
    }

    // MARK: - Guided auto-capture

    /// The photographer takes the shot: once the current guided shot has held good +
    /// steady, fire the full-quality capture, confirm, and advance. Disarms until the
    /// shot drops out of "ready" again so it shoots once per setup, not continuously.
    private func attemptGuidedCapture() {
        guard settings.autoCapture, settings.showGuides, !guide.steps.isEmpty,
              !allStepsDone, !uploading, !isReviewing, !calibrating,
              !camera.isRecording,   // don't auto-fire stills mid-clip
              camera.status == .ready else { return }
        autoArmed = false
        Task {
            let title = currentStep?.title
            let kept = await capture(trigger: .auto)   // burst + QC; advances only on a keeper
            coach?.resetHold()
            if kept, settings.speak, let title { coach?.announce("Got the \(title).") }
        }
    }

    /// Camera level / horizon indicator — fixed reference ticks plus a line that
    /// rolls with the device and snaps green when the camera is level. Like the
    /// system camera's level, so "straighten up" is something the pro can *see*.
    private func levelIndicator(_ roll: Double) -> some View {
        let isLevel = abs(roll) <= CoachTuning.tiltLevelDegrees
        return GeometryReader { geo in
            let cx = geo.size.width / 2, cy = geo.size.height / 2
            ZStack {
                // Fixed reference ticks (faint), centered.
                Rectangle().fill(.white.opacity(0.35)).frame(width: 26, height: 1.5)
                    .position(x: cx - 64, y: cy)
                Rectangle().fill(.white.opacity(0.35)).frame(width: 26, height: 1.5)
                    .position(x: cx + 64, y: cy)
                // Rolling line through the center.
                Rectangle()
                    .fill(isLevel ? BrandColor.emerald : .white.opacity(0.85))
                    .frame(width: 96, height: isLevel ? 2.5 : 1.5)
                    .shadow(color: isLevel ? BrandColor.emerald.opacity(0.7) : .clear, radius: 4)
                    .rotationEffect(.degrees(roll), anchor: .center)
                    .position(x: cx, y: cy)
                if isLevel {
                    Circle().fill(BrandColor.emerald).frame(width: 6, height: 6).position(x: cx, y: cy)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isLevel)
        }
        .allowsHitTesting(false)
    }

    // MARK: - ShotGuide (directed shoot)

    private var currentStep: ShotStep? {
        guide.steps.first { $0.id == currentStepID } ?? guide.steps.first
    }

    /// What the coach should expect of the frame right now — the current guided
    /// shot's expectations, or nil for freeform shooting (guides off / done).
    private var activeExpectations: ShotExpectations? {
        guard settings.showGuides, !guide.steps.isEmpty, !allStepsDone else { return nil }
        return currentStep?.expects
    }
    private var currentStepIndex: Int {
        guide.steps.firstIndex { $0.id == currentStepID } ?? 0
    }
    private var allStepsDone: Bool {
        !guide.steps.isEmpty && completedStepIDs.count >= guide.steps.count
    }

    /// Move the current-shot pointer (Prev/Next chevrons).
    private func selectStep(_ delta: Int) {
        let i = currentStepIndex + delta
        guard guide.steps.indices.contains(i) else { return }
        currentStepID = guide.steps[i].id
    }

    /// A successful capture completes the current guided shot and advances to the
    /// next one that hasn't been taken yet.
    private func markCurrentCaptured() {
        guard let id = currentStepID else { return }
        completedStepIDs.insert(id)
        if let next = guide.steps.first(where: { !completedStepIDs.contains($0.id) }) {
            currentStepID = next.id
        }
    }

    /// The directed-shoot bar: progress dots + the current shot (title + how-to) +
    /// Prev/Next, so the pro is guided through a complete, consistent set.
    private var guideBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(guide.steps) { step in
                    Circle()
                        .fill(completedStepIDs.contains(step.id) ? BrandColor.emerald
                              : (step.id == currentStepID ? .white : .white.opacity(0.3)))
                        .frame(width: 6, height: 6)
                }
                Spacer()
                Text("\(completedStepIDs.count)/\(guide.steps.count)")
                    .font(BrandFont.mono(11)).foregroundStyle(.white.opacity(0.7))
            }

            if allStepsDone {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(BrandColor.emerald)
                    Text("Full \(guide.name.lowercased()) captured — reshoot any, or tap Done")
                        .font(BrandFont.body(13, .semibold)).foregroundStyle(.white)
                    Spacer()
                }
            } else if let step = currentStep {
                HStack(spacing: 10) {
                    Button { selectStep(-1) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(currentStepIndex == 0 ? 0.25 : 0.85))
                    }
                    .disabled(currentStepIndex == 0)

                    Image(systemName: step.icon).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(BrandColor.accent).frame(width: 22)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text("Shot \(currentStepIndex + 1) · \(step.title)")
                                .font(BrandFont.body(14, .semibold)).foregroundStyle(.white)
                            if completedStepIDs.contains(step.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 12)).foregroundStyle(BrandColor.emerald)
                            }
                        }
                        Text(step.hint).font(BrandFont.body(11)).foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer()

                    Button { selectStep(1) } label: {
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(currentStepIndex >= guide.steps.count - 1 ? 0.25 : 0.85))
                    }
                    .disabled(currentStepIndex >= guide.steps.count - 1)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16).padding(.top, 10)
        .animation(.easeOut(duration: 0.2), value: currentStepID)
        .animation(.easeOut(duration: 0.2), value: allStepsDone)
    }

    // MARK: - Guidance banner (the photographer's voice)

    /// One clear directive for the current moment — sets the shot, calls the single
    /// most important fix, or says "hold steady" as it's about to capture.
    private var guidanceText: String {
        if allStepsDone { return "That's the full set — beautiful work." }
        let title = currentStep?.title ?? "Shot"
        if isReady { return "\(title) looks great — hold steady…" }
        if let fix = coach?.nudge?.message { return "\(title) — \(fix)" }
        if let hint = currentStep?.hint { return "\(title) — \(hint)" }
        return title
    }

    private var guidanceBanner: some View {
        let ready = isReady || allStepsDone
        return HStack(spacing: 10) {
            Image(systemName: allStepsDone ? "checkmark.seal.fill" : (isReady ? "camera.aperture" : "viewfinder"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ready ? BrandColor.emerald : BrandColor.accent)
            Text(guidanceText)
                .font(BrandFont.body(15, .semibold))
                .foregroundStyle(.white)
                .lineLimit(2).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder((ready ? BrandColor.emerald : BrandColor.accent).opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 16).padding(.top, 8)
        .animation(.easeOut(duration: 0.2), value: ready)
    }

    // MARK: - Light matching (before/after)

    /// Where this booking's locked white-balance gains persist (before + after
    /// share one calibration).
    private var wbDefaultsKey: String { "tovis.camera.wb.\(bookingId)" }

    /// Measure each before-reference's luma + warmth once (downscaled, same
    /// math as the live frame) — the target the after shoot matches.
    private func loadReferenceLight() async {
        for url in referenceURLs where referenceLight[url] == nil {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = CIImage(data: data, options: [.applyOrientationProperty: true])
            else { continue }
            let stamp = await Task.detached(priority: .utility) {
                let working = FrameMath.downscaled(image, maxDim: 240)
                let luma = FrameMath.averageLuma(working, context: FrameMath.context)
                let rgb = FrameMath.averageRGB(working, context: FrameMath.context) ?? (0.5, 0.5, 0.5)
                return LightStamp(luma: luma, warmth: FrameMath.warmth(rgb))
            }.value
            referenceLight[url] = stamp
        }
    }

    /// The live light vs the current before-reference: matched, or the single
    /// biggest mismatch phrased as a fix. Nil when there's nothing to match.
    private var lightMatch: (label: String, ok: Bool)? {
        guard showOnion, let url = currentReferenceURL, let stamp = referenceLight[url],
              let coach else { return nil }
        let dLuma = coach.frameLuma - stamp.luma
        let dWarmth = (coach.frameWarmth ?? stamp.warmth) - stamp.warmth
        // Normalize each axis by its tolerance so they compare fairly.
        let lumaSeverity = abs(dLuma) / CoachTuning.lightMatchLumaTolerance
        let warmthSeverity = abs(dWarmth) / CoachTuning.lightMatchWarmthTolerance
        if lumaSeverity <= 1, warmthSeverity <= 1 {
            return ("Light matches the before", true)
        }
        if lumaSeverity >= warmthSeverity {
            return (dLuma > 0 ? "Brighter than the before — dim a touch"
                              : "Darker than the before — add light", false)
        }
        return (dWarmth > 0 ? "Warmer than the before — cool the light"
                            : "Cooler than the before — warm the light", false)
    }

    /// The match-the-before light pill (AFTER phase, when a stamp is known).
    @ViewBuilder private var lightMatchPill: some View {
        if let match = lightMatch {
            HStack(spacing: 6) {
                Image(systemName: match.ok ? "checkmark.circle.fill" : "sun.max.trianglebadge.exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                Text(match.label).font(BrandFont.body(12, .semibold))
            }
            .foregroundStyle(match.ok ? BrandColor.emerald : BrandColor.gold)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            .overlay(Capsule().strokeBorder(
                (match.ok ? BrandColor.emerald : BrandColor.gold).opacity(0.5), lineWidth: 1))
        }
    }

    // MARK: - Onion-skin (before/after matching)

    /// Match-the-before controls: toggle the ghost, set its strength, and cycle
    /// which "before" to line up against. Only shown when references exist (AFTER).
    private var onionControls: some View {
        HStack(spacing: 12) {
            Button { onionEnabled.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: onionEnabled ? "square.on.square.dashed" : "square.on.square")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Match before").font(BrandFont.body(13, .semibold))
                }
                .foregroundStyle(onionEnabled ? BrandColor.onAccent : .white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(onionEnabled ? BrandColor.accent : .white.opacity(0.12), in: Capsule())
            }

            if showOnion {
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                Slider(value: $onionOpacity, in: 0.1...0.7).tint(.white)

                if referenceURLs.count > 1 {
                    Button {
                        referenceIndex = (referenceIndex + 1) % referenceURLs.count
                    } label: {
                        Text("\(min(referenceIndex, referenceURLs.count - 1) + 1)/\(referenceURLs.count)")
                            .font(BrandFont.mono(12)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Fundamentals HUD

    /// The order the fundamentals pills appear in (stable so they don't reshuffle
    /// frame-to-frame). Pose/clipping stays out of the row — it drives the priority
    /// tip when it fires, but an always-green "pose" pill just adds noise.
    private static let hudOrder: [CoachCategory] = [.lighting, .color, .level, .composition, .sharpness, .background]

    /// At-a-glance checklist: each fundamental tinted green (good) / amber (minor) /
    /// red (fix now), so the pro can *see* what's not photographer-worthy yet.
    private func fundamentalsHUD(_ statuses: [CoachStatus]) -> some View {
        HStack(spacing: 6) {
            ForEach(Self.hudOrder.compactMap { cat in statuses.first { $0.category == cat } }) { status in
                let info = Self.hudDisplay(status.category)
                HStack(spacing: 4) {
                    Image(systemName: info.icon).font(.system(size: 10, weight: .bold))
                    Text(info.label).font(BrandFont.mono(10)).tracking(0.5)
                }
                .foregroundStyle(Self.hudTint(status))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.black.opacity(0.45), in: Capsule())
                .overlay(Capsule().strokeBorder(Self.hudTint(status).opacity(0.5), lineWidth: 1))
            }
        }
        .padding(.top, 10)
        .animation(.easeOut(duration: 0.2), value: statuses)
    }

    private static func hudDisplay(_ c: CoachCategory) -> (label: String, icon: String) {
        switch c {
        case .lighting: return ("LIGHT", "sun.max.fill")
        case .color: return ("COLOR", "drop.fill")
        case .level: return ("LEVEL", "level.fill")
        case .composition: return ("FRAME", "viewfinder")
        case .sharpness: return ("FOCUS", "camera.metering.center.weighted")
        case .background: return ("CLEAN", "square.on.square")
        case .pose: return ("POSE", "figure.stand")
        }
    }

    /// Green when the fundamental is good, amber for a minor issue, red when it
    /// needs fixing now (a tip is present).
    private static func hudTint(_ s: CoachStatus) -> Color {
        guard s.message != nil else { return BrandColor.emerald }
        return s.score < 0.5 ? BrandColor.ember : BrandColor.gold
    }

    /// The single prioritized coaching tip.
    private func nudgeChip(_ message: String) -> some View {
        Text(message)
            .font(BrandFont.body(14, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(BrandColor.accent.opacity(0.6), lineWidth: 1))
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: message)
    }

    private var phaseHeader: some View {
        HStack {
            Button { requestExit() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.4), in: Circle())
            }
            Spacer()
            Text("\(phaseLabel) photos".uppercased())
                .font(BrandFont.mono(12))
                .tracking(1.2)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.4), in: Capsule())
            Spacer()
            Button { calibrating.toggle() } label: {
                Image(systemName: camera.whiteBalanceCalibrated ? "eyedropper.halffull" : "eyedropper")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(camera.whiteBalanceCalibrated ? BrandColor.emerald
                                     : (calibrating ? BrandColor.gold : .white))
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel("White balance calibration")

            Button { camera.setAEAFLock(!camera.aeAfLocked) } label: {
                HStack(spacing: 5) {
                    Image(systemName: camera.aeAfLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 14, weight: .semibold))
                    if camera.aeAfLocked {
                        Text("AE/AF").font(BrandFont.mono(10)).tracking(0.5)
                    }
                }
                .foregroundStyle(camera.aeAfLocked ? BrandColor.gold : .white)
                .padding(.horizontal, 11).frame(height: 38)
                .background(.black.opacity(0.4), in: Capsule())
            }
            .accessibilityLabel(camera.aeAfLocked ? "Unlock focus and exposure" : "Lock focus and exposure")

            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel("Coaching settings")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if calibrating { calibrationControls }
            lightMatchPill
            if !referenceURLs.isEmpty { onionControls }

            if let errorMessage {
                Text(errorMessage)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.ember)
                    .multilineTextAlignment(.center)
            }

            // Shots whose upload failed — kept locally, retried on demand.
            if !failedUploads.isEmpty {
                Button { Task { await retryFailedUploads() } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                        Text("Retry \(failedUploads.count) unsaved photo\(failedUploads.count == 1 ? "" : "s")")
                            .font(BrandFont.body(14, .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(BrandColor.ember.opacity(0.85), in: Capsule())
                }
                .disabled(uploading)
            }

            // Auto-harvested "best shots" awaiting review (Session Reel).
            if let coach, !coach.harvested.isEmpty {
                Button { showBestShots = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold))
                        Text("\(coach.harvested.count) best \(coach.harvested.count == 1 ? "shot" : "shots") — review")
                            .font(BrandFont.body(14, .semibold))
                    }
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(BrandColor.accent, in: Capsule())
                }
            }

            // Captured strip (this session)
            if !captured.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(captured) { shot in
                            Image(uiImage: shot.image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(height: 54)
            }

            // Shutter
            HStack {
                // Record control (left) — silent video clip → frame scrubber.
                Group {
                    if camera.recordingAvailable {
                        Button { Task { await toggleRecording() } } label: {
                            ZStack {
                                Circle().strokeBorder(.white.opacity(0.7), lineWidth: 2).frame(width: 44, height: 44)
                                RoundedRectangle(cornerRadius: camera.isRecording ? 4 : 11, style: .continuous)
                                    .fill(BrandColor.ember)
                                    .frame(width: camera.isRecording ? 20 : 22,
                                           height: camera.isRecording ? 20 : 22)
                                    .animation(.easeInOut(duration: 0.2), value: camera.isRecording)
                            }
                        }
                        .accessibilityLabel(camera.isRecording ? "Stop recording" : "Record clip")
                    } else if !captured.isEmpty {
                        Text("\(captured.count) captured")
                            .font(BrandFont.mono(11))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await capture() }
                } label: {
                    ZStack {
                        // Readiness ring (green = good to shoot), per the coach.
                        Circle()
                            .strokeBorder(readinessColor, lineWidth: 4)
                            .frame(width: 74, height: 74)
                            .animation(.easeInOut(duration: 0.3), value: readinessColor)
                        // Auto-capture "filling" ring — the photographer deciding,
                        // completing as the shot holds steady, then it fires.
                        Circle()
                            .trim(from: 0, to: coach?.holdProgress ?? 0)
                            .stroke(BrandColor.emerald, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 74, height: 74)
                            .animation(.linear(duration: 0.12), value: coach?.holdProgress ?? 0)
                        if uploading {
                            ProgressView().tint(.white)
                        } else {
                            // Dim + shrink the shutter when the coach says the shot
                            // isn't strong yet — a visible "hold for the green ring."
                            Circle().fill(.white).frame(width: 60, height: 60)
                                .scaleEffect(isReady ? 1.0 : 0.84)
                                .opacity(isReady ? 1.0 : 0.55)
                                .animation(.easeInOut(duration: 0.25), value: isReady)
                        }
                    }
                }
                .disabled(uploading || camera.status != .ready)

                // Done
                Button("Done") { requestExit() }
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 16)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    // MARK: - States

    private var permissionState: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 36)).foregroundStyle(.white.opacity(0.7))
            Text("Camera access needed")
                .font(BrandFont.display(20, .semibold)).foregroundStyle(.white)
            Text("Enable camera access in Settings to take session photos.")
                .font(BrandFont.body(14)).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(BrandFont.body(15, .semibold))
            .foregroundStyle(BrandColor.onAccent)
            .padding(.vertical, 12).padding(.horizontal, 28)
            .background(BrandColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button("Close") { dismiss() }.font(BrandFont.body(14)).foregroundStyle(.white.opacity(0.7))
        }
        .padding(28)
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message).font(BrandFont.body(15)).foregroundStyle(.white).multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .font(BrandFont.body(15, .semibold)).foregroundStyle(.white)
        }
        .padding(28)
    }

    // MARK: - Capture + upload

    private enum CaptureTrigger { case manual, auto }

    /// Take a shot. Manual = single capture, then the photographer check
    /// (post-capture QC on the real image) offers a retake if it failed.
    /// Auto = up to `autoCaptureAttempts` frames, keeping the first that
    /// passes QC — a photographer fires again; they don't keep the blink.
    /// Returns whether a shot was kept (uploaded + guide advanced).
    @discardableResult
    private func capture(trigger: CaptureTrigger = .manual) async -> Bool {
        // One capture at a time — the guided auto-shot and a manual shutter tap
        // can otherwise interleave (a second capturePhoto would be rejected by
        // the controller, but never let it get that far).
        guard !uploading else { return false }
        uploading = true
        errorMessage = nil
        defer { uploading = false }

        if trigger == .auto { return await autoCaptureBest() }

        let data: Data
        do {
            data = try await camera.capturePhoto()
        } catch {
            errorMessage = "Couldn’t take that photo. Please try again."
            return false
        }
        shutterFeedback()
        let qc = await PhotoQC.evaluate(data, checkBlink: blinkCheckApplies)
        if let reason = qc.retakeReason {
            pendingRetake = PendingRetake(data: data, reason: reason)
            return false
        }
        await finalize(data)
        return true
    }

    /// The auto-shot's burst: capture → QC → keep the first pass; if nothing
    /// passes, say why and let the hold re-arm (nothing uploads, the guide
    /// doesn't advance) — the subject is still in position for the next try.
    private func autoCaptureBest() async -> Bool {
        var best: (data: Data, qc: PhotoQCReport)?
        for _ in 0..<CoachTuning.autoCaptureAttempts {
            guard let data = try? await camera.capturePhoto() else { break }
            let qc = await PhotoQC.evaluate(data, checkBlink: blinkCheckApplies)
            if qc.passed { best = (data, qc); break }
            if best == nil || qc.sharpness > best!.qc.sharpness { best = (data, qc) }
        }
        guard let best else {
            errorMessage = "Couldn’t take that photo. Please try again."
            return false
        }
        guard best.qc.passed else {
            if settings.speak, let reason = best.qc.retakeReason {
                coach?.announce("\(reason) — let’s take that one again.")
            }
            errorMessage = best.qc.retakeReason.map { "\($0) — holding for another try." }
            return false
        }
        shutterFeedback()
        await finalize(best.data)
        return true
    }

    /// Whether the blink check applies to the current shot (skipped when closed
    /// eyes are intended — lash work — or no face belongs in frame).
    private var blinkCheckApplies: Bool {
        guard let expects = activeExpectations else { return true }
        return expects.face != .absent && !expects.allowsClosedEyes
    }

    /// Shutter confirmation: a brief flash + a light tap.
    private func shutterFeedback() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        withAnimation(.easeIn(duration: 0.18).delay(0.08)) { flash = false }
    }

    /// Keep a shot: thumbnail, complete the guided step, upload.
    private func finalize(_ data: Data) async {
        if let img = UIImage(data: data) { captured.insert(CapturedShot(image: img), at: 0) }
        markCurrentCaptured()   // complete the guided shot + advance
        await upload(data)
    }

    /// Upload one captured photo. On failure the bytes join the retry queue —
    /// a flaky connection must never lose a shot the pro already took.
    private func upload(_ data: Data) async {
        do {
            try await session.client.proMedia.uploadSessionPhoto(
                bookingId: bookingId,
                phase: phase,
                imageData: data
            )
            session.signalRefresh()   // the hub's gallery refreshes
        } catch let error as APIError {
            errorMessage = error.userMessage
            failedUploads.append(data)
        } catch {
            errorMessage = "Couldn’t save that photo — it’s kept here to retry."
            failedUploads.append(data)
        }
    }

    /// Re-attempt every queued failed upload; whatever fails again re-queues.
    private func retryFailedUploads() async {
        guard !uploading, !failedUploads.isEmpty else { return }
        uploading = true
        errorMessage = nil
        defer { uploading = false }
        let pending = failedUploads
        failedUploads = []
        for data in pending { await upload(data) }
    }

    private func toggleRecording() async {
        if camera.isRecording {
            errorMessage = nil
            if let url = try? await camera.stopRecording() {
                scrubClip = ScrubClip(url: url)   // → frame-by-frame review
            }
        } else {
            camera.startRecording()
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .before: return "Before"
        case .after: return "After"
        case .other: return "Session"
        }
    }

    /// Shutter ring color from the coach's readiness: red → amber → green.
    private var readinessColor: Color {
        guard settings.showReadinessRing, let readiness = coach?.readiness else { return .white }
        switch readiness {
        case ..<CoachTuning.readyWarnThreshold: return BrandColor.ember
        case ..<CoachTuning.readyThreshold: return BrandColor.gold
        default: return BrandColor.emerald
        }
    }
}

/// How the AI photographer guides the pro — the toggle sheet (gear in the camera).
private struct CoachSettingsSheet: View {
    @Bindable var settings: CoachSettings
    /// DEBUG tuning console entry — dismisses this sheet and opens the console
    /// over the LIVE camera (this sheet pauses it; tuning needs frames).
    var onOpenTuning: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Shot guide", isOn: $settings.showGuides)
                    Toggle("Fundamentals checklist", isOn: $settings.showChecklist)
                    Toggle("On-screen tips", isOn: $settings.showNudge)
                    Toggle("Speak tips aloud", isOn: $settings.speak)
                    Toggle("Haptic feedback", isOn: $settings.haptics)
                } header: {
                    Text("How it guides you")
                } footer: {
                    Text("The AI photographer coaches lighting and composition in real time. Pick how you'd like the tips.")
                }

                Section {
                    Toggle("Auto-capture each shot", isOn: $settings.autoCapture)
                    Toggle("Readiness ring", isOn: $settings.showReadinessRing)
                    Toggle("Level / horizon", isOn: $settings.showLevel)
                    Toggle("Rule-of-thirds grid", isOn: $settings.showGrid)
                    Toggle("Crop-safe guide (4:5 · 9:16)", isOn: $settings.showCropGuide)
                    Toggle("Extra best-shots (background)", isOn: $settings.autoHarvest)
                } header: {
                    Text("On the camera")
                } footer: {
                    Text("Auto-capture takes each guided shot for you once it looks great and holds steady — like a photographer pressing the shutter at the right moment. You can always tap the shutter yourself.")
                }

                #if DEBUG
                Section("Developer") {
                    Button("Coach tuning console") {
                        dismiss()
                        onOpenTuning?()
                    }
                    .disabled(onOpenTuning == nil)
                }
                #endif
            }
            .navigationTitle("Camera coaching")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .tint(BrandColor.accent)
        .presentationDetents([.medium, .large])
    }
}
