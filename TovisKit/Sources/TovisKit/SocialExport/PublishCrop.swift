// The crops beauty work actually SHIPS in, as geometry rather than decoration.
//
// The camera captures 3:4 and publishes 9:16 — the Tovis Looks feed is a
// full-screen cover-cropped pager, so a 3:4 capture loses ~40% of its width the
// moment it is published. The crop-safe overlay has drawn that box for a while;
// the coach was never told about it, so it could call a frame perfectly
// composed — green ring, auto-capture fires — while the published crop took the
// sides off it.
//
// This file is the ONE source of that geometry: `ProCapturePhotosView` draws
// these rects, `CompositionCoach` judges inside them, and `SocialExportPlan`
// cuts the exported file to them — so the frame the coach approves is the frame
// that ships, and the frame that ships is the frame that gets posted.
//
// 🔴 It lives in TovisKit rather than beside the camera because CI compiles and
// tests TovisKit and nothing compiles the `Tovis/` app target. This is arithmetic
// that decides what a pro's published photo looks like; a sign error here crops
// somebody's client out of their own before/after and no test would have seen it.
// Moved here from `Tovis/PublishCrop.swift` when the social export pack landed.
import CoreGraphics

public enum PublishCrop {
    /// The upright capture frame's aspect (w/h) — the `.photo` preset's 3:4.
    public static let captureAspect: CGFloat = 3.0 / 4.0

    /// Reels / TikTok / Shorts / the Tovis Looks feed.
    public static let feed: CGFloat = 9.0 / 16.0
    /// Instagram's tallest feed post.
    public static let instagramFeed: CGFloat = 4.0 / 5.0

    /// The centered crop of `aspect` (w/h) inside a capture frame of
    /// `frameAspect`, as a normalized TOP-LEFT rect of that frame.
    public static func rect(aspect: CGFloat, frameAspect: CGFloat = captureAspect) -> CGRect {
        guard aspect > 0, frameAspect > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        if aspect > frameAspect {
            // Wider than the frame → full width, cropped height.
            let h = frameAspect / aspect
            return CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
        // Narrower → full height, cropped width.
        let w = aspect / frameAspect
        return CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
    }

    /// The feed crop of the live capture frame — what `CompositionCoach` judges
    /// inside when the pro has the crop guide on.
    public static var feedRect: CGRect { rect(aspect: feed) }

    // MARK: - Reels cover safe band

    // A Reel's COVER is what stops the scroll, and the platform lays its own
    // chrome over the top and bottom of it. On a 1080×1920 cover that is
    // roughly the top 220 px (profile row) and the bottom 450 px (caption,
    // audio, action rail). Published, fixed numbers — nothing to tune.
    public static let coverSafeTopFraction: CGFloat = 220.0 / 1920.0
    public static let coverSafeBottomFraction: CGFloat = 450.0 / 1920.0

    /// The part of a 9:16 crop that survives the Reels cover chrome — a pure
    /// inset by fractions of the box's own height, so it is correct in whatever
    /// space the box is given in (normalized frame space, or the preview
    /// layer's points).
    public static func coverSafeRect(in feedRect: CGRect) -> CGRect {
        let top = feedRect.height * coverSafeTopFraction
        let bottom = feedRect.height * coverSafeBottomFraction
        let height = feedRect.height - top - bottom
        guard height > 0 else { return feedRect }
        return CGRect(x: feedRect.minX, y: feedRect.minY + top,
                      width: feedRect.width, height: height)
    }

    // MARK: - Judging inside a crop

    /// Re-express a normalized frame-space rect in a crop's OWN 0…1 space, so
    /// the existing headroom / centering rules judge the picture that ships
    /// rather than the sensor frame it was cut from. Values outside the crop
    /// come back outside 0…1 — callers decide what that means.
    public static func inCropSpace(_ r: CGRect, crop: CGRect) -> CGRect {
        guard crop.width > 0, crop.height > 0 else { return r }
        return CGRect(
            x: (r.minX - crop.minX) / crop.width,
            y: (r.minY - crop.minY) / crop.height,
            width: r.width / crop.width,
            height: r.height / crop.height
        )
    }

    /// Same mapping for a point.
    public static func inCropSpace(_ p: CGPoint, crop: CGRect) -> CGPoint {
        guard crop.width > 0, crop.height > 0 else { return p }
        return CGPoint(x: (p.x - crop.minX) / crop.width, y: (p.y - crop.minY) / crop.height)
    }
}
