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
    /// The arithmetic itself lives in `LookFeedLayout.windowBox` — the same
    /// function the letterboxed feed frame uses, so a cover crop cannot mean one
    /// thing here and another there. This is the (size, offset) shape the
    /// existing callers want.
    func coverCrop(imageSize: CGSize, containerSize: CGSize) -> (size: CGSize, offset: CGSize) {
        let box = LookFeedLayout.windowBox(
            window: imageSize,
            container: containerSize,
            fit: .cover,
            focal: self
        )
        // A degenerate image or container falls back to a centered fill, which is
        // what every caller of this has always been handed.
        guard box.width > 0, box.height > 0 else { return (containerSize, .zero) }
        return (box.size, CGSize(width: box.minX, height: box.minY))
    }
}
