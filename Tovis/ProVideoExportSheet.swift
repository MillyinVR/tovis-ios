// The video counterpart to `ProSocialExportSheet` — deliberately much smaller.
// There is no format picker (a clip ships at its own aspect, not a chosen
// canvas), no pair toggle (video never pairs — `ProMediaExportContext.hasPair`
// is false for it) and no crop slider (clip length/crop is a follow-up,
// HANDOFF-camera-redesign.md). What's left is: look at it, sign it, leave with
// it — same as the picture sheet's Share/Save, on a plain preview.
import SwiftUI
import TovisKit

struct ProVideoExportSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let context: ProMediaExportContext
    /// Shared with the presenting surface so identity is loaded once.
    let model: ProMediaExportModel
    var identity: MediaExportIdentity = .own

    @State private var posterImage: UIImage?
    @State private var overlayImage: UIImage?
    @State private var posterAspect: CGFloat = 9.0 / 16.0
    @State private var rendering = false
    @State private var sharing: ExportFile?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    previewPane
                    MediaExportSignatureNote(watermark: model.exportWatermark, identity: identity)
                    if case let .failed(message) = model.phase {
                        Text(message)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.ember)
                    }
                    if case let .done(message) = model.phase {
                        Text(message)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.emerald)
                    }
                }
                .padding(20)
                .padding(.bottom, 96)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(BrandColor.textSecondary)
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
        }
        .tint(BrandColor.accent)
        .task {
            switch identity {
            case .own:
                await model.loadIdentity(session.client)
            case let .client(professionalId):
                await model.loadIdentity(session.client, forProfessionalId: professionalId)
            }
            await loadPreview()
        }
        .sheet(item: $sharing) { file in
            ShareSheet(items: [file.url])
        }
    }

    // MARK: - Preview

    /// A poster frame with the SAME `SocialExportRenderer.watermarkOverlay`
    /// this export bakes into every real frame, composited on top — the
    /// signature/mark are pixel-identical in DESIGN and proportion to the real
    /// export (same font, same right-aligned corner, same fraction of the
    /// short edge), just rendered at the poster's own bounded size rather than
    /// the source's full resolution. Cheap enough to show immediately, unlike
    /// running a full `AVAssetExportSession` just to preview.
    @ViewBuilder
    private var previewPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(BrandColor.bgSecondary)
            if let posterImage {
                Image(uiImage: posterImage)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        if let overlayImage {
                            Image(uiImage: overlayImage).resizable()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ProgressView().tint(BrandColor.accent)
            }
            if rendering {
                Color.black.opacity(0.15)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .aspectRatio(posterAspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 340)
    }

    private func loadPreview() async {
        guard case let .remote(url) = context.main,
              let posterData = await ClipVault.poster(for: url),
              let poster = UIImage(data: posterData),
              let cgPoster = poster.cgImage
        else { return }
        posterImage = poster
        let size = CGSize(width: cgPoster.width, height: cgPoster.height)
        posterAspect = size.height > 0 ? size.width / size.height : posterAspect
        if let overlay = SocialExportRenderer.watermarkOverlay(model.exportWatermark, canvasSize: size) {
            overlayImage = UIImage(cgImage: overlay)
        }
    }

    private var navigationTitle: String {
        if case .client = identity { return "Share" }
        return "Make a post"
    }

    // MARK: - Actions

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await share() }
            } label: {
                actionLabel("Share", systemImage: "square.and.arrow.up", primary: true)
            }
            .buttonStyle(.plain)
            .disabled(rendering)

            Button {
                Task { await saveExport() }
            } label: {
                actionLabel("Save to Photos", systemImage: "arrow.down.circle", primary: false)
            }
            .buttonStyle(.plain)
            .disabled(rendering)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func actionLabel(_ title: String, systemImage: String, primary: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
            Text(title).font(BrandFont.body(14, .semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .foregroundStyle(primary ? BrandColor.onAccent : BrandColor.accent)
        .background(primary ? BrandColor.accent : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandColor.accent.opacity(primary ? 0 : 0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func share() async {
        rendering = true
        defer { rendering = false }
        model.clearStatus()
        do {
            let url = try await model.renderVideoExport(context)
            sharing = ExportFile(url: url)
        } catch {
            model.setFailure("Couldn’t build that export. Try again.")
        }
    }

    private func saveExport() async {
        rendering = true
        defer { rendering = false }
        do {
            let url = try await model.renderVideoExport(context)
            await model.savePhotosCopyVideo(of: url)
        } catch {
            model.setFailure("Couldn’t build that export. Try again.")
        }
    }
}
