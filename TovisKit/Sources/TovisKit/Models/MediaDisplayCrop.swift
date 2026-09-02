import CoreGraphics

// What a cover-cropping SURFACE needs from a media row: the rect to display, and
// the subject focal ALREADY remapped into that rect's space.
//
// The exact twin of web `lib/media/cropRect.ts` → `resolveDisplayCrop`, and it
// exists for the same reason: every surface that honours the stored rect — the
// looks feed, every 3:4 browse tile, the 4:5 heroes, the pro's own library —
// needs the same three steps, and doing them by hand at each call site is
// precisely how one of them ends up handing a cropping view an uncropped focal.
// That failure does not crash and does not look wrong in review; it just posts
// somebody's shoulder where their face should be.
//
// 🔴 VIDEO is excluded here, and WEB makes the SAME exclusion. A clip's frame has
// to come from its poster and that is unbuilt on both platforms; honouring a rect
// on one platform only would put one look in two shapes, which is the exact
// defect this whole track exists to fix.

/// The pair a cropping view is handed: never one without the other.
public struct MediaDisplayCrop: Sendable, Equatable {
    /// The window of the stored image to display, or nil for the full frame.
    public let crop: MediaCropRect?
    /// The subject focal IN `crop`'s space, or nil to centre.
    public let focal: MediaFocalPoint?

    public init(crop: MediaCropRect?, focal: MediaFocalPoint?) {
        self.crop = crop
        self.focal = focal
    }

    /// The full stored frame, centred — what a row with no rect and no focal
    /// renders, and what a surface with nothing to show should pass.
    public static let fullFrame = MediaDisplayCrop(crop: nil, focal: nil)
}

/// A wire model that carries a publish crop and a focal for the same asset.
public protocol MediaCropDisplayable {
    /// Video is excluded from the rect on both platforms — see the note above.
    var isVideo: Bool { get }
    /// The validated rect, or nil for the full stored frame.
    var cropRect: MediaCropRect? { get }
    /// The stored focal, measured on the UNCROPPED frame.
    var focalPoint: MediaFocalPoint? { get }
}

public extension MediaCropDisplayable {
    /// The rect and the crop-space focal, together. 🔴 The ONLY thing a cropping
    /// view should read — `cropRect` and `focalPoint` separately is the bug.
    var displayCrop: MediaDisplayCrop {
        let crop = isVideo ? nil : cropRect
        // No crop → crop space IS frame space, so this returns the focal
        // unchanged and the surface renders exactly as it did before.
        return MediaDisplayCrop(crop: crop, focal: focalPoint?.inCropSpace(crop))
    }
}
