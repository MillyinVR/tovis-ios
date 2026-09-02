// A remote image that fills + cover-crops its frame, centering the crop window on
// a subject focal point (camera C6 / C6c) when one is supplied. It is the SwiftUI
// counterpart of the web feed's `object-fit: cover` + `object-position` (see
// `MediaFocalPoint.coverCrop`): a 3:4 capture in the full-screen 9:16 feed loses
// a quarter of its width blind-center, so we place the visible window on the face.
//
// Two paths, by design:
//  • Neither a focal nor a stored crop (the common case, and every row today) →
//    a plain center `.scaledToFill()` AsyncImage. Byte-identical to pre-C6c, and
//    it keeps AsyncImage's in-memory decoded cache for that majority.
//  • A focal or a CROP present → the decode-bounded UIImage path (like
//    DownsampledRemoteImage) so we know the intrinsic size and can place the
//    window exactly. Only those images pay for the extra decode.
//
// The crop is capture-chain item 4's other half: "one crop per look, applied
// EVERYWHERE". The feed honoured the pro's stored rect from item 3 while every
// grid tile and hero still derived its own window from the master, so a pro who
// re-framed a look watched it change in the feed and nowhere else.
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
    ///
    /// 🔴 When `crop` is also supplied this must ALREADY be in crop space —
    /// `MediaDisplayCrop.focal`, never the model's raw `focalPoint`. The stored
    /// focal is measured on the uncropped frame; handing it in raw silently
    /// shows the wrong part of the photograph.
    let focal: MediaFocalPoint?
    /// The pro's published frame — the window of the stored image to display, or
    /// nil for the full stored frame (every row today, and byte-identical to
    /// before this existed). Pair it with `focal` via `MediaDisplayCrop`.
    var crop: MediaCropRect? = nil
    /// Long-edge decode budget for the focal path (the nil path lets AsyncImage
    /// decide). Grids can pass a smaller value than a full-screen slide.
    var maxPixel: CGFloat = ImageDownsample.screenMaxPixel
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var failure: () -> Failure

    @State private var focalImage: UIImage?
    @State private var focalLoadFailed = false

    var body: some View {
        // A crop needs the intrinsic size just as much as a focal does — the
        // window cannot be laid out without it — so both take the decoded path.
        if focal != nil || crop != nil {
            GeometryReader { geo in
                Group {
                    if let focalImage {
                        focalFill(focalImage, container: geo.size)
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

    /// Draw the crop window at cover scale, anchored on `focal` exactly where CSS
    /// `object-position` would put it, then clip to the container.
    ///
    /// `CropWindowLayer` is shared with the feed's `LookFeedImage`. With
    /// `crop == nil` its source box IS its window box, so this reduces to the
    /// same focal-anchored `.scaledToFill()` it has always drawn — the invariant
    /// `LookFeedLayoutTests` pins.
    private func focalFill(_ image: UIImage, container: CGSize) -> some View {
        CropWindowLayer(
            image: image,
            crop: crop,
            container: container,
            fit: .cover,
            focal: focal
        )
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

    /// URLs currently being prefetched, so a fast scroll cannot start the same
    /// download several times over. MainActor-isolated rather than locked —
    /// every caller is a view.
    @MainActor private static var inFlight: Set<String> = []

    /// Fetch and decode `url` into the cache BEFORE anything asks to draw it, so
    /// the view that eventually does gets a cache hit instead of a spinner.
    ///
    /// Cheap to over-call: returns immediately if the image is already cached or
    /// already being fetched, and silently gives up on any failure — a prefetch
    /// that doesn't arrive costs nothing, because the view still loads normally.
    ///
    /// 🔴 `maxPixel` must match what the eventual view will ask for. The cache is
    /// keyed on URL **and** pixel budget, so prefetching at the wrong budget
    /// stores a bitmap nothing will ever look up and doubles the download.
    @MainActor
    static func prefetch(_ url: URL, maxPixel: CGFloat = ImageDownsample.screenMaxPixel) async {
        if image(for: url, maxPixel: maxPixel) != nil { return }

        let inFlightKey = key(url, maxPixel) as String
        if inFlight.contains(inFlightKey) { return }
        inFlight.insert(inFlightKey)
        defer { inFlight.remove(inFlightKey) }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let decoded = await ImageDownsample.thumbnail(from: data, maxPixel: maxPixel)
        else { return }

        store(decoded, url: url, maxPixel: maxPixel)
    }
}

extension FocalCoverImage where Failure == Placeholder {
    /// Convenience: reuse the placeholder as the failure view (grid tiles whose
    /// placeholder is already a neutral fill don't need a distinct error state).
    init(
        url: URL,
        focal: MediaFocalPoint?,
        crop: MediaCropRect? = nil,
        maxPixel: CGFloat = ImageDownsample.screenMaxPixel,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(
            url: url,
            focal: focal,
            crop: crop,
            maxPixel: maxPixel,
            placeholder: placeholder,
            failure: placeholder
        )
    }

    /// The call every cropping surface should make: the rect and its crop-space
    /// focal together, straight off the wire model, so neither can be forgotten.
    init(
        url: URL,
        display: MediaDisplayCrop,
        maxPixel: CGFloat = ImageDownsample.screenMaxPixel,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(
            url: url,
            focal: display.focal,
            crop: display.crop,
            maxPixel: maxPixel,
            placeholder: placeholder,
            failure: placeholder
        )
    }
}
