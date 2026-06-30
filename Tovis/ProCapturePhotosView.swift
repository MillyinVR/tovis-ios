// Pro session photo capture — the custom camera for BEFORE/AFTER session photos.
// Phase A: live preview + shutter → upload (presign→PUT→confirm) + a strip of
// what you've shot this session. The on-device AI coach (overlays, readiness
// ring, pose templates) layers onto this preview in Phase B.
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
    /// Local thumbnails of shots taken this session (newest first) — shown
    /// instantly from the captured bytes, no network round-trip.
    @State private var captured: [UIImage] = []
    @State private var uploading = false
    @State private var errorMessage: String?
    /// Brief white flash on a successful capture (shutter confirmation).
    @State private var flash = false

    // AI photographer (Phase B1): live coach + how-it-guides toggles.
    @State private var settings = CoachSettings()
    @State private var coach: CoachEngine?
    @State private var showSettings = false
    @State private var showBestShots = false
    /// Guards exit while the coach has auto-harvested best shots the pro hasn't
    /// reviewed yet — otherwise tapping Done silently discards them.
    @State private var showExitConfirm = false
    /// A just-recorded clip awaiting frame-by-frame review (nil = none).
    @State private var scrubClip: ScrubClip?

    private struct ScrubClip: Identifiable { let url: URL; var id: String { url.absoluteString } }

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
            await camera.start(frameDelegate: engine.analyzer)
        }
        .onDisappear { camera.stop(); coach?.stop() }
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
        }
        .sheet(isPresented: $showSettings) {
            CoachSettingsSheet(settings: settings)
        }
        .sheet(isPresented: $showBestShots) {
            if let coach {
                BestShotsReviewView(coach: coach, bookingId: bookingId, phase: phase)
            }
        }
        .fullScreenCover(item: $scrubClip) { clip in
            FrameScrubberView(videoURL: clip.url, bookingId: bookingId, phase: phase)
        }
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
                    CameraPreview(session: camera.session)
                        .ignoresSafeArea(edges: .top)
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
                    }
                    if settings.showChecklist, let statuses = coach?.statuses, !statuses.isEmpty {
                        fundamentalsHUD(statuses)
                    }
                    if settings.showNudge, let message = coach?.nudge?.message {
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
            if !referenceURLs.isEmpty { onionControls }

            if let errorMessage {
                Text(errorMessage)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.ember)
                    .multilineTextAlignment(.center)
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
                        ForEach(Array(captured.enumerated()), id: \.offset) { _, img in
                            Image(uiImage: img)
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

    private func capture() async {
        uploading = true
        errorMessage = nil
        defer { uploading = false }
        do {
            let data = try await camera.capturePhoto()
            // Shutter confirmation: a brief flash + a light tap.
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.easeOut(duration: 0.08)) { flash = true }
            withAnimation(.easeIn(duration: 0.18).delay(0.08)) { flash = false }
            if let img = UIImage(data: data) { captured.insert(img, at: 0) }
            markCurrentCaptured()   // complete the guided shot + advance
            try await session.client.proMedia.uploadSessionPhoto(
                bookingId: bookingId,
                phase: phase,
                imageData: data
            )
            session.signalRefresh()   // the hub's gallery refreshes
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn’t save that photo. Please try again."
        }
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

                Section("On the camera") {
                    Toggle("Readiness ring", isOn: $settings.showReadinessRing)
                    Toggle("Level / horizon", isOn: $settings.showLevel)
                    Toggle("Rule-of-thirds grid", isOn: $settings.showGrid)
                    Toggle("Auto-capture best shots", isOn: $settings.autoHarvest)
                }
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
