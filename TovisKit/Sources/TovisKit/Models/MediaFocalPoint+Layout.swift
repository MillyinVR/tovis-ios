import CoreGraphics

// Focal-aware cover-crop geometry (camera C6, render side / C6c). The web feed
// centers its full-screen `object-fit: cover` window on the subject via CSS
// `object-position` (`lib/media/focalPoint.ts` → `focalObjectPosition`). SwiftUI
// has no `object-position`, so we reproduce it: scale the image to fill the
// container (like `.scaledToFill()`) and offset it so the focal point lands where
// `object-position: x% y%` would put it. Because the focal is normalized [0,1]
// top-left (the same convention the web uses), the offset is a plain linear
// interpolation and is naturally clamped — a null/absent focal never reaches here
// (the caller center-crops), so the visible window can never fall past an edge.

public extension MediaFocalPoint {
    /// The cover-crop layout for an image of `imageSize` displayed to fill
    /// `containerSize`, with the crop window positioned on this focal point per
    /// CSS `object-position` (the web feed's rule).
    ///
    /// Returns the size the image should be drawn at (scaled to cover, preserving
    /// aspect) and the top-left `offset` to apply. On the overflowing axis the
    /// offset is `≤ 0` and spans exactly `[container − scaled, 0]`, so the window
    /// stays on the image — the same clamp `object-position` applies. A degenerate
    /// (zero) image or container falls back to a centered `containerSize` fill.
    func coverCrop(imageSize: CGSize, containerSize: CGSize) -> (size: CGSize, offset: CGSize) {
        let cw = containerSize.width, ch = containerSize.height
        let iw = imageSize.width, ih = imageSize.height
        guard iw > 0, ih > 0, cw > 0, ch > 0 else {
            return (containerSize, .zero)
        }
        // `.scaledToFill()`: the larger of the two axis ratios covers the frame.
        let scale = max(cw / iw, ch / ih)
        let scaled = CGSize(width: iw * scale, height: ih * scale)
        // (container − scaled) ≤ 0 on the overflow axis; x/y ∈ [0,1] keep it clamped.
        let offset = CGSize(
            width: (cw - scaled.width) * x,
            height: (ch - scaled.height) * y
        )
        return (scaled, offset)
    }
}
