// Draws the stored publish crop — the window of a photo the pro published — into
// whatever box it is given.
//
// The SwiftUI half of `TovisKit.LookFeedLayout` (which owns the arithmetic), and
// the twin of web's `app/_components/media/CropWindowFrame.tsx`. It exists as its
// own view because TWO callers need it — `LookFeedImage` (the feed's contained
// slide) and `FocalCoverImage` (every 3:4 browse tile and every hero) — and a
// second hand-rolled copy of a crop layout is a second chance to show the wrong
// part of somebody's photograph.
//
// 🔴 `focal` must ALREADY be in crop space (`MediaDisplayCrop.focal`). The stored
// focal is measured on the UNCROPPED frame; handing it in raw anchors the window
// on the wrong place, with no crash and nothing wrong-looking in a diff.
import SwiftUI
import TovisKit
import UIKit

struct CropWindowLayer: View {
    let image: UIImage
    /// The window to display, or nil for the full stored frame — in which case
    /// the source box IS the window box and this reduces to a plain
    /// focal-anchored fill/fit, exactly as before the rect existed.
    let crop: MediaCropRect?
    let container: CGSize
    let fit: LookFeedLayout.Fit
    /// Already in crop space. A `.contain` fit shows the whole window, so there
    /// is no spare pixel for a focal to spend — pass nil there.
    let focal: MediaFocalPoint?

    var body: some View {
        // Three nested frames, matching web's three nested boxes: the source
        // drawn oversized and back-shifted, clipped to the window box, then
        // offset into the container.
        let window = LookFeedLayout.windowSize(crop: crop, natural: image.size)
        let box = LookFeedLayout.windowBox(
            window: window,
            container: container,
            fit: fit,
            focal: focal
        )
        let source = LookFeedLayout.sourceBox(crop: crop, windowBox: box.size)

        Image(uiImage: image)
            .resizable()
            .frame(width: source.width, height: source.height)
            .offset(x: source.minX, y: source.minY)
            .frame(width: box.width, height: box.height, alignment: .topLeading)
            .clipped()
            .offset(x: box.minX, y: box.minY)
            .frame(width: container.width, height: container.height, alignment: .topLeading)
            .clipped()
    }
}
