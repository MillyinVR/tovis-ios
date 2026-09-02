import CoreGraphics

// The non-destructive publish CROP of a MediaAsset — the rect of the STORED
// image a surface should display, normalized [0,1] from the TOP-LEFT origin.
// The twin of web `lib/media/cropRect.ts`, and deliberately in the SAME space
// and the SAME convention as `MediaFocalPoint` (the original, EXIF-corrected
// upright image), so the two compose without a conversion.
//
// nil (no crop on the wire) means "the full stored frame" — identical to the
// pre-crop behaviour — so every legacy row and every surface renders exactly as
// it did until a rect is supplied. Nothing renders it yet; the wire models carry
// it so the re-frame editor can adopt it without another schema round.
//
// 🔴 It lives in TovisKit rather than beside a view for the same reason
// `PublishCrop` does: `swift test` reaches it on every PR with no simulator, and
// this is arithmetic that decides which part of a client's photograph the world
// sees. See `MediaCropRectTests`.

public struct MediaCropRect: Sendable, Equatable {
    /// Origin, normalized [0,1] from the top-left of the stored image.
    public let x: Double
    public let y: Double
    /// Extent, normalized. Always > 0, and x+w / y+h never exceed the frame.
    public let w: Double
    public let h: Double

    /// Slack for float comparisons. A rect that round-trips through JSON, a
    /// Float8 column and a Double can land a few ULPs outside the unit square
    /// without meaning to. Matches web's `EPSILON` in `lib/media/cropRect.ts`.
    private static let epsilon = 1e-6

    /// Validated init — nil unless ALL FOUR are present, finite, and describe a
    /// non-degenerate rect inside the frame.
    ///
    /// All-or-nothing on purpose: three of four coordinates is not a degraded
    /// crop, it is an unanswerable one, and a view handed a partial rect has no
    /// honest frame to draw. Mirrors web `resolveCropRect`.
    public init?(x: Double?, y: Double?, w: Double?, h: Double?) {
        guard let x, let y, let w, let h,
              x.isFinite, y.isFinite, w.isFinite, h.isFinite,
              w > 0, h > 0,
              x >= -Self.epsilon, y >= -Self.epsilon,
              x + w <= 1 + Self.epsilon, y + h <= 1 + Self.epsilon
        else { return nil }
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    /// The whole stored image — what a nil crop means.
    public static let fullFrame = MediaCropRect(x: 0, y: 0, w: 1, h: 1)!

    /// As a `CGRect` in the stored image's normalized space, so it can be handed
    /// straight to `PublishCrop`.
    public var rect: CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// Re-express a focal point in this crop's OWN [0,1] space.
    ///
    /// 🔴 THE DANGEROUS ONE. `MediaFocalPoint` is measured on the UNCROPPED
    /// frame — PhotoQC and the camera's face detection judge the whole capture —
    /// and this rect is in that same frame. A view that displays only the crop
    /// window needs the focal relative to THAT window. Handing it the uncropped
    /// focal silently mis-centres the cover-crop: it does not crash, it does not
    /// look wrong in review, it just posts somebody's shoulder.
    ///
    /// The mapping is `PublishCrop.inCropSpace`, the same arithmetic the coach
    /// already uses to judge inside the publish crop — one implementation, so a
    /// sign error cannot exist in one place and not the other.
    ///
    /// Returns nil when the focal falls OUTSIDE this crop (the subject was
    /// framed out): a position a cover-crop cannot honour is not a position, and
    /// the caller should centre instead.
    public func focalInCropSpace(_ focal: MediaFocalPoint) -> MediaFocalPoint? {
        let mapped = PublishCrop.inCropSpace(
            CGPoint(x: focal.x, y: focal.y),
            crop: rect
        )
        // `MediaFocalPoint.init?` rejects anything outside [0,1], which is
        // exactly "framed out" — but clamp the epsilon slack first so a focal
        // sitting exactly on an edge is not lost to a rounding artefact.
        return MediaFocalPoint(
            x: Self.clampToUnit(Double(mapped.x)),
            y: Self.clampToUnit(Double(mapped.y))
        )
    }

    /// Clamp away the epsilon slack only; anything genuinely outside stays
    /// outside so `MediaFocalPoint.init?` can reject it.
    private static func clampToUnit(_ value: Double) -> Double {
        if value < 0, value >= -epsilon { return 0 }
        if value > 1, value <= 1 + epsilon { return 1 }
        return value
    }
}

public extension MediaFocalPoint {
    /// This focal expressed inside `crop`, or unchanged when there is no crop
    /// (crop space IS frame space then). nil when the subject was framed out.
    ///
    /// The call a cropping view should make instead of reading `x`/`y` directly.
    func inCropSpace(_ crop: MediaCropRect?) -> MediaFocalPoint? {
        guard let crop else { return self }
        return crop.focalInCropSpace(self)
    }
}
