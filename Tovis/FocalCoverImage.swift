// A remote image that fills + cover-crops its frame, centering the crop window on
// a subject focal point (camera C6 / C6c) when one is supplied. It is the SwiftUI
// counterpart of the web feed's `object-fit: cover` + `object-position` (see
// `MediaFocalPoint.coverCrop`): a 3:4 capture in the full-screen 9:16 feed loses
// a quarter of its width blind-center, so we place the visible window on the face.
//
// Two paths, by design:
//  • No focal (the common case, and every row until web C6a #613 deploys) →
//    a plain center `.scaledToFill()` AsyncImage. Byte-identical to pre-C6c, and
//    it keeps AsyncImage's in-memory decoded cache for the nil-focal majority.
//  • A focal present → the decode-bounded UIImage path (like DownsampledRemoteImage)
//    so we know the intrinsic size and can offset the fill exactly. Only the
//    images that actually carry a focal pay for the extra decode.
//
// The caller supplies the bounding frame + clip (every call site is a fill
// context); this view fills whatever space it's given.
import SwiftUI
import TovisKit
import UIKit

struct FocalCoverImage<Placeholder: View, Failure: View>: View {
    let url: URL
    /// The subject focal point to center the cover-crop on, or nil for a plain
    /// centered fill (identical to `.scaledToFill()`).
    let focal: MediaFocalPoint?
    /// Long-edge decode budget for the focal path (the nil path lets AsyncImage
    /// decide). Grids can pass a smaller value than a full-screen slide.
    var maxPixel: CGFloat = ImageDownsample.screenMaxPixel
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var failure: () -> Failure

    @State private var focalImage: UIImage?
    @State private var focalLoadFailed = false

    var body: some View {
        if let focal {
            GeometryReader { geo in
                Group {
                    if let focalImage {
                        focalFill(focalImage, focal: focal, container: geo.size)
                    } else if focalLoadFailed {
                        failure()
                    } else {
                        placeholder()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .task(id: url) { await loadFocalImage() }
        } else {
            // `Color.clear` anchors the layout to the PROPOSED size; the image fills
            // it as an overlay so `.scaledToFill()`'s overflow is clipped instead of
            // inflating the parent's layout. Without this, a landscape photo in a
            // portrait full-bleed slot reports its scaled-up width (e.g. 972pt for a
            // 402pt-wide slide) as its own width, widening the Looks slide's ZStack
            // and shoving the leading overlays + trailing rail off both edges. Grids
            // that pass a definite `.frame` were unaffected either way.
            Color.clear
                .overlay {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image): image.resizable().scaledToFill()
                        case .failure: failure()
                        default: placeholder()
                        }
                    }
                }
                .clipped()
        }
    }

    /// Draw the image at cover scale, offset so `focal` lands where CSS
    /// `object-position` would put it, then clip to the container.
    private func focalFill(_ image: UIImage, focal: MediaFocalPoint, container: CGSize) -> some View {
        let layout = focal.coverCrop(imageSize: image.size, containerSize: container)
        return Image(uiImage: image)
            .resizable()
            .frame(width: layout.size.width, height: layout.size.height)
            .offset(x: layout.offset.width, y: layout.offset.height)
            .frame(width: container.width, height: container.height, alignment: .topLeading)
            .clipped()
    }

    private func loadFocalImage() async {
        focalLoadFailed = false

        // A cache hit resolves BEFORE the nil reset below, so a tile that has
        // already been decoded comes straight back instead of flashing its
        // placeholder on every re-appearance.
        if let cached = FocalImageCache.image(for: url, maxPixel: maxPixel) {
            focalImage = cached
            return
        }

        focalImage = nil
        guard let (data, _) = try? await URLSession.shared.data(from: url) else {
            focalLoadFailed = true
            return
        }
        if let image = await ImageDownsample.thumbnail(from: data, maxPixel: maxPixel) {
            FocalImageCache.store(image, url: url, maxPixel: maxPixel)
            focalImage = image
        } else {
            focalLoadFailed = true
        }
    }
}

/// Decoded-image cache for the focal path — and for `LookFeedImage`, which needs
/// a decoded bitmap for the same reason (it has to know the intrinsic size before
/// it can lay a crop window out). Shared rather than duplicated, so a look
/// decoded by one is free for the other.
///
/// 🔴 Why this had to exist before the profile grids could use `FocalCoverImage`:
/// the nil-focal branch is an `AsyncImage`, which keeps its own in-memory cache of
/// DECODED images. The focal branch fetches and decodes by hand and had none — so
/// every time a view re-appeared it re-ran `URLSession` (bytes may come from
/// URLCache; the decode never does) and re-decoded from scratch.
///
/// That was survivable while the only caller was the feed, which shows one slide
/// at a time. It is not survivable on a 60-tile portfolio grid that scrolls, which
/// is exactly what `MediaGridImage` became a caller of — and those tiles all gain a
/// focal the moment the server starts sending one, so the regression would have
/// arrived on its own, without an app release, the day the API change deployed.
///
/// Keyed on `maxPixel` as well as the URL: the same asset is legitimately decoded
/// at a tile budget and at the screen budget, and handing a 512px bitmap to a
/// full-width Signature card would render it soft.
///
/// `NSCache` is thread-safe and evicts itself under memory pressure, so this can
/// never become the jetsam source the capture pipeline already learned to avoid.
enum FocalImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        return cache
    }()

    private static func key(_ url: URL, _ maxPixel: CGFloat) -> NSString {
        "\(url.absoluteString)|\(Int(maxPixel))" as NSString
    }

    static func image(for url: URL, maxPixel: CGFloat) -> UIImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    static func store(_ image: UIImage, url: URL, maxPixel: CGFloat) {
        cache.setObject(image, forKey: key(url, maxPixel))
    }
}

extension FocalCoverImage where Failure == Placeholder {
    /// Convenience: reuse the placeholder as the failure view (grid tiles whose
    /// placeholder is already a neutral fill don't need a distinct error state).
    init(
        url: URL,
        focal: MediaFocalPoint?,
        maxPixel: CGFloat = ImageDownsample.screenMaxPixel,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(url: url, focal: focal, maxPixel: maxPixel, placeholder: placeholder, failure: placeholder)
    }
}
