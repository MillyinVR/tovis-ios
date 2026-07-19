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

    enum Source {
        case remote(url: URL, isVideo: Bool)
        case localImage(UIImage)
    }

    /// Build from a remote URL string; `nil` when there's no usable URL.
    static func remote(
        id: String,
        urlString: String?,
        isVideo: Bool,
        overlay: MediaCaptionOverlay? = nil
    ) -> FullscreenMedia? {
        guard let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, let url = URL(string: raw) else { return nil }
        return FullscreenMedia(
            id: id,
            source: .remote(url: url, isVideo: isVideo),
            overlay: overlay
        )
    }

    /// A locally-held image (e.g. the in-camera captured strip).
    static func local(id: String, image: UIImage) -> FullscreenMedia {
        FullscreenMedia(id: id, source: .localImage(image), overlay: nil)
    }
}

extension FullscreenMedia {
    /// Convenience for a session media row (best full render URL + kind).
    static func session(_ item: ProBookingMediaItem) -> FullscreenMedia? {
        remote(id: item.id, urlString: item.displayUrl, isVideo: item.mediaType == .video)
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
        }
        .statusBarHidden(true)
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
