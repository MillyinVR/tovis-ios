// Full-screen media viewer — the "tap a thumbnail to see it full size" surface
// used anywhere the app shows small media (session before/after, aftercare,
// client chart, reviews, portfolio, message attachments). Images and videos.
//
// Deliberately reuses the app's decode-bounded image path (`ImageDownsample`)
// instead of `AsyncImage`: session/portfolio shots are served at full capture
// resolution, and decoding those to a full bitmap is exactly what jetsam-killed
// the camera before. Video uses AVKit `VideoPlayer` here (not the feed's
// chromeless `LookVideoView`) because a "view this clip" surface wants transport
// controls.
import AVKit
import SwiftUI
import TovisKit
import UIKit

/// A single piece of media to present full-screen. Either a remote URL (image
/// or video) or an already-decoded local image (a freshly captured shot that
/// hasn't been uploaded yet).
struct FullscreenMedia: Identifiable {
    let id: String
    let source: Source
    /// Caption + service chips to overlay, mirroring web's `/media/[id]` panel.
    /// `nil` on every surface that has no such metadata (message attachments,
    /// chart photos, the capture strip) — those keep the bare viewer.
    let overlay: MediaCaptionOverlay?

    /// Save + export affordances. `nil` everywhere by default, and set only by
    /// surfaces that offer it (pro-owned media, or a client-facing surface via
    /// `clientExportable`). `exportIdentity` decides whose signature it
    /// carries and which affordances show — see `MediaExportIdentity`.
    var export: ProMediaExportContext?
    var exportIdentity: MediaExportIdentity = .own

    enum Source {
        case remote(url: URL, isVideo: Bool)
        case localImage(UIImage)
    }

    /// Build from a remote URL string; `nil` when there's no usable URL.
    static func remote(
        id: String,
        urlString: String?,
        isVideo: Bool,
        overlay: MediaCaptionOverlay? = nil,
        export: ProMediaExportContext? = nil
    ) -> FullscreenMedia? {
        guard let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, let url = URL(string: raw) else { return nil }
        return FullscreenMedia(
            id: id,
            source: .remote(url: url, isVideo: isVideo),
            overlay: overlay,
            export: export
        )
    }

    /// A locally-held image (e.g. the in-camera captured strip).
    static func local(id: String, image: UIImage) -> FullscreenMedia {
        FullscreenMedia(id: id, source: .localImage(image), overlay: nil)
    }

    /// The PRO's own asset, with save + export offered.
    ///
    /// `beforeUrlString` is the paired "before" when the surface knows of one,
    /// which is what unlocks the diptych — an unpaired shot still exports as a
    /// single. Videos get save only; the still pack is stills.
    static func proOwned(
        id: String,
        urlString: String?,
        isVideo: Bool,
        focal: MediaFocalPoint? = nil,
        beforeUrlString: String? = nil,
        beforeFocal: MediaFocalPoint? = nil,
        overlay: MediaCaptionOverlay? = nil
    ) -> FullscreenMedia? {
        guard let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, let url = URL(string: raw) else { return nil }
        let before = beforeUrlString
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return FullscreenMedia(
            id: id,
            source: .remote(url: url, isVideo: isVideo),
            overlay: overlay,
            export: ProMediaExportContext(
                main: .remote(url),
                focal: focal,
                before: before.map { .remote($0) },
                beforeFocal: beforeFocal,
                isVideo: isVideo
            )
        )
    }
}

extension FullscreenMedia {
    /// A CLIENT viewing media exports/shares it signed with the PRO's handle —
    /// their own aftercare before/after, or the pro's portfolio/Looks/review
    /// work. Signed-export only, no plain unmarked save (see
    /// `MediaExportIdentity.client`'s doc for why one rule covers both).
    ///
    /// `beforeUrlString`, when the surface has one, unlocks the diptych
    /// formats — the before/after payoff is the natural thing to share, same
    /// as `.proOwned`.
    ///
    /// `isVideo` gets no bar at all rather than an export bar with nothing to
    /// offer — video export is unbuilt for EVERY identity (`ProMediaExportContext
    /// .canExport` is false for it), and unlike the `.own` path there is no
    /// Save button to keep the bar non-empty on the client path (see
    /// `MediaExportIdentity.client`'s doc for why Save is never offered here).
    static func clientExportable(
        id: String,
        urlString: String?,
        isVideo: Bool,
        professionalId: String,
        beforeUrlString: String? = nil,
        overlay: MediaCaptionOverlay? = nil
    ) -> FullscreenMedia? {
        guard let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, let url = URL(string: raw) else { return nil }
        if isVideo {
            return FullscreenMedia(id: id, source: .remote(url: url, isVideo: true), overlay: overlay)
        }
        let before = beforeUrlString
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return FullscreenMedia(
            id: id,
            source: .remote(url: url, isVideo: false),
            overlay: overlay,
            export: ProMediaExportContext(
                main: .remote(url),
                before: before.map { .remote($0) },
                isVideo: false
            ),
            exportIdentity: .client(professionalId: professionalId)
        )
    }

    /// Convenience for a session media row (best full render URL + kind).
    static func session(_ item: ProBookingMediaItem) -> FullscreenMedia? {
        remote(id: item.id, urlString: item.displayUrl, isVideo: item.mediaType == .video)
    }

    /// The same row, opened by the PRO from their own session — save + export on.
    /// `before` is the session's paired "before" shot when there is one.
    static func proSession(
        _ item: ProBookingMediaItem,
        before: ProBookingMediaItem? = nil
    ) -> FullscreenMedia? {
        proOwned(
            id: item.id,
            urlString: item.displayUrl,
            isVideo: item.mediaType == .video,
            beforeUrlString: item.mediaType == .video ? nil : before?.displayUrl
        )
    }
}

extension View {
    /// Present the full-screen media viewer for the bound item, tapping to close.
    func mediaFullscreenCover(_ item: Binding<FullscreenMedia?>) -> some View {
        fullScreenCover(item: item) { media in
            MediaFullscreenViewer(media: media) { item.wrappedValue = nil }
        }
    }
}

struct MediaFullscreenViewer: View {
    let media: FullscreenMedia
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The bar is attached at the bottom of this stack — see `exportBar`.
            Color.black.ignoresSafeArea()

            switch media.source {
            case let .remote(url, isVideo):
                if isVideo {
                    FullscreenVideo(url: url)
                } else {
                    ZoomableRemoteImage(url: url)
                }
            case let .localImage(image):
                ZoomableImage(uiImage: image)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(.leading, 16)
            .padding(.top, 8)
            .accessibilityLabel("Close")

            if let overlay = media.overlay {
                // Bottom-anchored inside the same ZStack so it sits above the
                // zoomable image without intercepting its pinch/drag gestures.
                VStack {
                    Spacer()
                    MediaCaptionPanel(overlay: overlay)
                }
                .allowsHitTesting(false)
            }

            if let export = media.export {
                VStack {
                    Spacer()
                    ProMediaExportBar(context: export, identity: media.exportIdentity)
                }
            }
        }
        .statusBarHidden(true)
    }
}

// MARK: - Save + export bar

/// Save + export, as one bar — used by the fullscreen viewer and the
/// practice-shot detail so both offer exactly the same thing in the same
/// words. `identity` (`.own` — a pro's own work; `.client` — a client
/// exporting a pro's) decides which of the two buttons show; see
/// `MediaExportIdentity`.
///
/// 🔴 "Save to Photos" and "Make a post" are deliberately separate buttons rather
/// than one action with options. They produce different files: a save is the
/// ORIGINAL (untouched bytes, EXIF intact, never watermarked) and an export is
/// a new, cropped, signed picture. Collapsing them into one control is how a
/// pro ends up with a watermark on the photo they meant to archive — the same
/// reason `.client` never offers Save at all (see `MediaExportIdentity`).
struct ProMediaExportBar: View {
    @Environment(SessionModel.self) private var session

    let context: ProMediaExportContext
    var identity: MediaExportIdentity = .own

    @State private var model = ProMediaExportModel()
    @State private var exporting = false

    var body: some View {
        VStack(spacing: 8) {
            if let status = statusLine {
                Text(status)
                    .font(BrandFont.body(12))
                    .foregroundStyle(.white.opacity(0.9))
            }

            HStack(spacing: 10) {
                if case .own = identity {
                    Button {
                        Task { await model.saveOriginal(context.main) }
                    } label: {
                        label("Save to Photos", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking)
                }

                if showsExportButton {
                    Button { exporting = true } label: {
                        label(exportButtonTitle, systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.plain)
                }
            }

            if case .client = identity, model.identityLoaded, !model.clientExportIsEnabled {
                Text("This pro has turned off sharing.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 28)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .task {
            switch identity {
            case .own:
                await model.loadIdentity(session.client)
            case let .client(professionalId):
                await model.loadIdentity(session.client, forProfessionalId: professionalId)
            }
        }
        .sheet(isPresented: $exporting) {
            ProSocialExportSheet(context: context, model: model, identity: identity)
        }
    }

    private var isWorking: Bool {
        if case .working = model.phase { return true }
        return false
    }

    /// Hidden entirely once a `.client` load confirms the pro turned sharing
    /// off, rather than offering a button that would just refuse the tap.
    /// Shows optimistically before that load resolves (generous default,
    /// `ProMediaExportModel.clientExportIsEnabled`) — in practice this task
    /// finishes well before the fullscreen viewer's open animation does.
    private var showsExportButton: Bool {
        guard context.canExport else { return false }
        if case .client = identity { return model.clientExportIsEnabled }
        return true
    }

    private var exportButtonTitle: String {
        if case .client = identity { return "Share" }
        return "Make a post"
    }

    private var statusLine: String? {
        switch model.phase {
        case .idle: nil
        case let .working(message): message
        case let .failed(message): message
        case let .done(message): message
        }
    }

    private func label(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title).font(BrandFont.body(13, .semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Caption + services panel

/// Web's `/media/[id]` bottom panel: the caption line, then a "Services" label
/// above name chips. Rendered only when ``MediaCaptionOverlay`` has something.
private struct MediaCaptionPanel: View {
    let overlay: MediaCaptionOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let caption = overlay.caption {
                Text(caption)
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !overlay.serviceNames.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SERVICES")
                        .font(BrandFont.body(11, .semibold))
                        .kerning(0.8)
                        .foregroundStyle(.white.opacity(0.7))

                    FlowChips(names: overlay.serviceNames)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 28)
    }
}

/// Wrapping row of service chips. `LazyVGrid` would force equal columns and
/// truncate a long service name, so the chips flow at their natural width.
private struct FlowChips: View {
    let names: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(names, id: \.self) { chip($0) }
            }
        }
    }

    private var chips: some View {
        ForEach(names, id: \.self) { chip($0) }
    }

    private func chip(_ name: String) -> some View {
        Text(name)
            .font(BrandFont.body(11, .semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(.white.opacity(0.16), in: Capsule())
    }
}

// MARK: - Video

private struct FullscreenVideo: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player).ignoresSafeArea()
            } else {
                Color.black
            }
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

// MARK: - Image

/// Loads a remote image decode-bounded to screen size, then shows it zoomable.
private struct ZoomableRemoteImage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableImage(uiImage: image)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: url) {
            image = nil
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            image = await ImageDownsample.thumbnail(from: data, maxPixel: ImageDownsample.screenMaxPixel)
        }
    }
}

/// Fit-to-screen image with pinch-zoom, drag-pan (when zoomed), and double-tap
/// to toggle zoom.
private struct ZoomableImage: View {
    let uiImage: UIImage

    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        let liveScale = min(max(scale * pinch, 1), 5)

        Image(uiImage: uiImage)
            .resizable()
            .scaledToFit()
            .scaleEffect(liveScale)
            .offset(x: offset.width + drag.width, y: offset.height + drag.height)
            .gesture(
                MagnificationGesture()
                    .updating($pinch) { value, state, _ in state = value }
                    .onEnded { value in
                        scale = min(max(scale * value, 1), 5)
                        if scale == 1 { offset = .zero }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .updating($drag) { value, state, _ in
                        if scale > 1 { state = value.translation }
                    }
                    .onEnded { value in
                        guard scale > 1 else { return }
                        offset.width += value.translation.width
                        offset.height += value.translation.height
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3)) {
                    if scale > 1 {
                        scale = 1
                        offset = .zero
                    } else {
                        scale = 2.5
                    }
                }
            }
            .ignoresSafeArea()
    }
}
