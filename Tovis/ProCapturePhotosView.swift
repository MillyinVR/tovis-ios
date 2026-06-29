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

    @State private var camera = CameraController()
    /// Local thumbnails of shots taken this session (newest first) — shown
    /// instantly from the captured bytes, no network round-trip.
    @State private var captured: [UIImage] = []
    @State private var uploading = false
    @State private var errorMessage: String?

    // AI photographer (Phase B1): live coach + how-it-guides toggles.
    @State private var settings = CoachSettings()
    @State private var coach: CoachEngine?
    @State private var showSettings = false

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
        }
        .task {
            let engine = coach ?? CoachEngine(settings: settings)
            coach = engine
            await camera.start(frameDelegate: engine.analyzer)
        }
        .onDisappear { camera.stop() }
        .sheet(isPresented: $showSettings) {
            CoachSettingsSheet(settings: settings)
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

                if settings.showGrid { thirdsGrid }

                VStack(spacing: 0) {
                    phaseHeader
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
            Button { dismiss() } label: {
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
            if let errorMessage {
                Text(errorMessage)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.ember)
                    .multilineTextAlignment(.center)
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
                Text(captured.isEmpty ? "" : "\(captured.count) captured")
                    .font(BrandFont.mono(11))
                    .foregroundStyle(.white.opacity(0.7))
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
                            Circle().fill(.white).frame(width: 60, height: 60)
                        }
                    }
                }
                .disabled(uploading || camera.status != .ready)

                // Done
                Button("Done") { dismiss() }
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
            if let img = UIImage(data: data) { captured.insert(img, at: 0) }
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
        case ..<0.5: return BrandColor.ember
        case ..<0.8: return BrandColor.gold
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
