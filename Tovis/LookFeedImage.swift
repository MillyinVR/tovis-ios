// The Looks feed's media frame: the look CONTAINED — the whole published frame,
// nothing cropped away — over a blurred, cover-cropped copy of itself filling
// whatever the aspect ratios leave over.
//
// The SwiftUI twin of web's `LookMedia` → `LetterboxFrame`, and it must stay
// that way: one look, one shape, both platforms. The geometry both sides use is
// `TovisKit.LookFeedLayout`, tested against the same worked numbers.
//
// ── Why contain and not fill ───────────────────────────────────────────────
// Tori's ask, verbatim: media should "take the full page like TikTok's For You
// page, preferably without it cropping anything". A phone slide is roughly 1:2
// and every look in the database is a 3:4 capture, so `.scaledToFill()` — what
// this replaces — was throwing away a THIRD of the width of every look in the
// back catalogue, blind, and usually an arm or the ends of the hair. Containing
// it stops the crop; the blurred self-backdrop is what keeps the page full
// instead of leaving the photo marooned in two dead bars. It is also exactly
// what TikTok and Reels do with off-ratio media.
//
// As the stored rect (capture-chain item 2) gets closer to the slide's own
// shape the bars shrink to nothing: a 9:16 frame — what the masked viewfinder
// will shoot, item 1 — leaves 44pt on a 787pt slide, and the backdrop stops
// being visible at all. Nothing here needs to change when that lands.
//
// ── Why it decodes rather than using AsyncImage ────────────────────────────
// It needs the intrinsic size: a crop window cannot be laid out without it, and
// the same decoded bitmap then draws BOTH layers, so the backdrop is free
// rather than a second decode of the same photo. `FocalImageCache` (shared with
// `FocalCoverImage`) keeps it off the network on every re-appearance.
import SwiftUI
import TovisKit
import UIKit

struct LookFeedImage<Placeholder: View, Failure: View>: View {
    let url: URL
    /// The stored original, used ONLY if `url` fails to load.
    ///
    /// `url` is now usually the server's downscaled render of this look, which
    /// Supabase serves from its image-transformation endpoint — documented as a
    /// Pro-plan feature while this project is on Free. It works today, but if it
    /// ever stops, every slide in the feed would fail at once. Falling back to
    /// the original turns a blank feed into a slow one. nil → no fallback.
    var fallbackURL: URL? = nil
    /// The pro's published frame, or nil for the full stored image (every look
    /// today). The window this frame displays.
    let crop: MediaCropRect?
    /// 🔴 The subject focal ALREADY IN CROP SPACE — `item.focalPointInCrop`,
    /// never `item.focalPoint`. It anchors the backdrop's cover crop; handing in
    /// the raw focal (measured on the uncropped frame) silently anchors on the
    /// wrong part of the photograph, and nothing about it looks wrong in review.
    let focalInCrop: MediaFocalPoint?
    var maxPixel: CGFloat = ImageDownsample.screenMaxPixel
    @ViewBuilder var placeholder: () -> Placeholder
    @ViewBuilder var failure: () -> Failure

    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    ZStack {
                        LookFeedBackdrop.blurred(
                            layer(
                                image,
                                container: LookFeedBackdrop.grown(geo.size),
                                fit: .cover,
                                focal: focalInCrop
                            ),
                            container: geo.size
                        )
                        // A contain fit shows the whole window, so there is no
                        // spare pixel for a focal to spend — the same rule web's
                        // MediaFill has always applied.
                        layer(image, container: geo.size, fit: .contain, focal: nil)
                    }
                } else if loadFailed {
                    failure()
                } else {
                    placeholder()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .task(id: url) { await load() }
    }

    /// Draw the crop window into `container` at the given fit.
    ///
    /// The layout itself is `CropWindowLayer`, shared with `FocalCoverImage` so
    /// the feed and every grid tile cannot drift into two different windows of
    /// the same photograph.
    private func layer(
        _ image: UIImage,
        container: CGSize,
        fit: LookFeedLayout.Fit,
        focal: MediaFocalPoint?
    ) -> some View {
        CropWindowLayer(
            image: image,
            crop: crop,
            container: container,
            fit: fit,
            focal: focal
        )
    }

    private func load() async {
        loadFailed = false

        // A cache hit resolves BEFORE the nil reset below, so a slide that has
        // already been decoded comes straight back instead of flashing its
        // placeholder every time the pager returns to it.
        if let cached = FocalImageCache.image(for: url, maxPixel: maxPixel) {
            image = cached
            return
        }

        image = nil

        // The render URL first; the stored original only if it does not arrive.
        // Deduped: an asset with no thumb resolves `thumbOrFullURL` to `url`, so
        // both candidates are the same file and a failure would fetch it twice.
        var candidates = [url]
        if let fallbackURL, fallbackURL != url { candidates.append(fallbackURL) }

        for candidate in candidates {
            guard let (data, _) = try? await URLSession.shared.data(from: candidate),
                  let decoded = await ImageDownsample.thumbnail(from: data, maxPixel: maxPixel)
            else { continue }

            FocalImageCache.store(decoded, url: candidate, maxPixel: maxPixel)
            image = decoded
            return
        }

        loadFailed = true
    }
}

/// The blurred backdrop treatment, in one place because the video slide needs
/// exactly the same thing behind its poster.
enum LookFeedBackdrop {
    /// How far the backdrop is grown past the slide on every edge, in points.
    ///
    /// A blur samples transparency beyond the view it is applied to, so a layer
    /// blurred at exactly the slide's size fades out around its own edge and
    /// leaves a pale vignette inside the visible area. Growing it past the slide
    /// by more than the blur's visible reach puts that fade off-screen by
    /// construction rather than by eye. Same 80 as web's `BACKDROP_OVERSCAN_PX`.
    static let overscan: CGFloat = 80

    /// Matches web's `blur(24px)`. Not a byte-identical kernel — CSS and Core
    /// Image do not blur the same way — but the same visual weight, and the
    /// GEOMETRY (which is what "one look, one shape" is about) is exact.
    static let blurRadius: CGFloat = 24

    /// Web dims with `brightness(0.62)`, which is precisely "multiply by 0.62",
    /// which is precisely black at 38% over the top. So: black at 38%, not
    /// SwiftUI's `.brightness`, which is an ADDITIVE shift and would not match.
    static let dim: Double = 0.38

    /// Matches web's `saturate(1.2)`.
    static let saturation: Double = 1.2

    static func grown(_ container: CGSize) -> CGSize {
        CGSize(width: container.width + overscan * 2, height: container.height + overscan * 2)
    }

    /// Blur, enrich and dim `content` (laid out at {@link grown} size), then clip
    /// it back to the slide so the blur's own fade stays off-screen.
    @ViewBuilder
    static func blurred<Content: View>(_ content: Content, container: CGSize) -> some View {
        content
            .saturation(saturation)
            .blur(radius: blurRadius)
            .overlay(Color.black.opacity(dim))
            .frame(width: container.width, height: container.height)
            .clipped()
            .allowsHitTesting(false)
    }
}

extension LookFeedImage where Failure == Placeholder {
    /// Convenience: reuse the placeholder as the failure view.
    init(
        url: URL,
        fallbackURL: URL? = nil,
        crop: MediaCropRect?,
        focalInCrop: MediaFocalPoint?,
        maxPixel: CGFloat = ImageDownsample.screenMaxPixel,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(
            url: url,
            fallbackURL: fallbackURL,
            crop: crop,
            focalInCrop: focalInCrop,
            maxPixel: maxPixel,
            placeholder: placeholder,
            failure: placeholder
        )
    }
}
