import CoreGraphics

// DISPLAY geometry for the publish crop — where a crop window lands inside a
// container, in points. The read-side twin of `MediaCropRect` (which owns the
// rect itself) and the exact port of web `lib/media/cropWindow.ts`. Pure
// arithmetic: no SwiftUI, no UIKit, no image decoding.
//
// ── Why it exists ──────────────────────────────────────────────────────────
// `.scaledToFit()` / `.scaledToFill()` can only fit the WHOLE image. Once a
// stored rect says "display this window of the image", they have no way to
// express it — the window is smaller than the source, so the view has to zoom,
// and neither modifier takes a zoom. So a cropping view positions the source by
// hand: a clipping box the size of the window, with the whole source oversized
// and offset inside it. These three functions are that arithmetic.
//
// ── The invariant that keeps the two paths honest ──────────────────────────
// With `crop == nil` (the full frame — every look today) these numbers are
// exactly `.scaledToFill()` / `.scaledToFit()` with a focal anchor, which is
// why `MediaFocalPoint.coverCrop` is now written in terms of `windowBox` rather
// than repeating the same three lines beside it.
//
// 🔴 Load-bearing arithmetic, like `PublishCrop`: a sign error here does not
// crash and does not look wrong in a diff — it just shows the wrong part of
// somebody's photograph. `LookFeedLayoutTests` pins it to the same worked
// numbers as web's `cropWindow.test.ts`.

public enum LookFeedLayout {
    /// How a window is scaled into its container.
    public enum Fit: Sendable {
        /// The largest scale that fits — letterbox bars appear. Nothing cropped.
        case contain
        /// The smallest scale that covers — the overflow is clipped.
        case cover
    }

    /// `UnitPoint(0.5, 0.5)` — dead centre, and what "no focal" means.
    private static let centre = CGPoint(x: 0.5, y: 0.5)

    /// The point size of the crop window on a source of intrinsic size `natural`.
    /// A nil crop is the full frame, so the window IS the source.
    public static func windowSize(crop: MediaCropRect?, natural: CGSize) -> CGSize {
        guard let crop else { return natural }
        return CGSize(width: natural.width * crop.w, height: natural.height * crop.h)
    }

    /// Place a window of size `window` inside `container`, scaled to `fit` and
    /// anchored on `focal` (nil → centred).
    ///
    /// The anchor spends the free space — negative when covering — exactly the
    /// way CSS `object-position` spends it, so web and iOS put the same part of
    /// the photograph on screen.
    ///
    /// Returns `.zero` for a degenerate window or container rather than an
    /// infinity: a view with nothing measured yet draws nothing, which is also
    /// the consent-safe answer.
    public static func windowBox(
        window: CGSize,
        container: CGSize,
        fit: Fit,
        focal: MediaFocalPoint? = nil
    ) -> CGRect {
        guard window.width > 0, window.height > 0,
              container.width > 0, container.height > 0,
              window.width.isFinite, window.height.isFinite,
              container.width.isFinite, container.height.isFinite
        else { return .zero }

        let scaleX = container.width / window.width
        let scaleY = container.height / window.height
        let scale = fit == .contain ? min(scaleX, scaleY) : max(scaleX, scaleY)

        let size = CGSize(width: window.width * scale, height: window.height * scale)
        let anchor = focal.map { CGPoint(x: $0.x, y: $0.y) } ?? centre

        return CGRect(
            x: (container.width - size.width) * anchor.x,
            y: (container.height - size.height) * anchor.y,
            width: size.width,
            height: size.height
        )
    }

    /// Where the WHOLE source sits inside a window box of size `windowBox`, so
    /// that the window's own origin lands at the box's top-left.
    ///
    /// The source is scaled up by 1/w × 1/h (so the window fills the box exactly)
    /// and pulled back by the window's origin. The result always carries the
    /// SOURCE's aspect ratio when `windowBox` carries the window's — which
    /// {@link windowBox} guarantees — so drawing the image stretched into this
    /// rect is exact, not a distortion.
    ///
    /// A nil crop is the full frame: the source is the box, unscaled, unshifted.
    public static func sourceBox(crop: MediaCropRect?, windowBox: CGSize) -> CGRect {
        guard windowBox.width > 0, windowBox.height > 0 else { return .zero }
        guard let crop else {
            return CGRect(origin: .zero, size: windowBox)
        }

        let width = windowBox.width / crop.w
        let height = windowBox.height / crop.h

        return CGRect(x: -crop.x * width, y: -crop.y * height, width: width, height: height)
    }
}
