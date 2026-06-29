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
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }

    // MARK: - Camera UI

    private var cameraUI: some View {
        VStack(spacing: 0) {
            // Live preview
            ZStack(alignment: .top) {
                if camera.status == .ready {
                    CameraPreview(session: camera.session)
                        .ignoresSafeArea(edges: .top)
                } else {
                    Color.black
                    ProgressView().tint(.white)
                }
                phaseHeader
            }

            controls
        }
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
            // Spacer to balance the close button.
            Color.clear.frame(width: 38, height: 38)
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
                        Circle().strokeBorder(.white, lineWidth: 4).frame(width: 74, height: 74)
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
}
