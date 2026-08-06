// The camera composes for a 3:4 sensor and publishes to a 9:16 feed. These pin
// the geometry that bridges the two — and, more importantly, that the coach and
// the on-screen guide read it from the same place, so the lines can't promise
// one thing while the green ring approves another.
import CoreGraphics
import Testing
import TovisKit
@testable import Tovis

@Suite struct PublishCropTests {
    @Test func theFeedCropTakesTheSidesOffA3x4Frame() {
        let feed = PublishCrop.feedRect
        // 9:16 is narrower than 3:4 → full height, centered width.
        #expect(feed.minY == 0)
        #expect(feed.height == 1)
        #expect(abs(feed.width - 0.75) < 1e-9)
        #expect(abs(feed.minX - 0.125) < 1e-9)
        // The plan's "~40% of the width" claim, stated as arithmetic: a 3:4
        // capture keeps 75% of its width, so a quarter is lost outright and the
        // usable area drops by the same.
        #expect(abs((1 - feed.width) - 0.25) < 1e-9)
    }

    @Test func the4x5CropIsWiderThanTheFeedCropAndBothAreCentered() {
        let ig = PublishCrop.rect(aspect: PublishCrop.instagramFeed)
        let feed = PublishCrop.feedRect
        #expect(ig.width > feed.width)
        #expect(abs(ig.midX - 0.5) < 1e-9)
        #expect(abs(feed.midX - 0.5) < 1e-9)
    }

    @Test func aWiderThanFrameCropLosesHeightInstead() {
        let wide = PublishCrop.rect(aspect: 16.0 / 9.0)
        #expect(wide.width == 1)
        #expect(wide.height < 1)
        #expect(abs(wide.midY - 0.5) < 1e-9)
    }

    @Test func degenerateAspectsFallBackToTheWholeFrame() {
        #expect(PublishCrop.rect(aspect: 0) == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(PublishCrop.rect(aspect: 1, frameAspect: 0)
                    == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: - Reels cover safe band

    @Test func theCoverSafeBandReservesMoreRoomBelowThanAbove() {
        let feed = PublishCrop.feedRect
        let safe = PublishCrop.coverSafeRect(in: feed)
        let top = safe.minY - feed.minY
        let bottom = feed.maxY - safe.maxY
        #expect(bottom > top)                                   // caption rail is the big one
        #expect(abs(top - 220.0 / 1920.0) < 1e-9)
        #expect(abs(bottom - 450.0 / 1920.0) < 1e-9)
        #expect(safe.minX == feed.minX && safe.width == feed.width)
    }

    /// It insets by fractions of the box's own height, so it is correct whether
    /// it is handed a normalized frame rect or a preview-layer rect in points —
    /// which is how the overlay draws it (see `coverSafeBand`).
    @Test func theBandScalesWithWhateverSpaceItIsGiven() {
        let points = CGRect(x: 40, y: 100, width: 300, height: 533)
        let safe = PublishCrop.coverSafeRect(in: points)
        #expect(abs((safe.minY - points.minY) / points.height
                        - PublishCrop.coverSafeTopFraction) < 1e-9)
        #expect(abs((points.maxY - safe.maxY) / points.height
                        - PublishCrop.coverSafeBottomFraction) < 1e-9)
    }

    /// A degenerate box (before the preview layer has geometry) comes back
    /// untouched rather than inverted — the overlay draws nothing rather than
    /// a negative-height rectangle.
    @Test func aDegenerateBoxIsReturnedUntouched() {
        let flat = CGRect(x: 0, y: 0, width: 10, height: 0)
        #expect(PublishCrop.coverSafeRect(in: flat) == flat)
    }

    // MARK: - Judging inside the crop

    @Test func cropSpaceRescalesAFaceOntoThePublishedPicture() {
        let feed = PublishCrop.feedRect
        // A face at the frame's horizontal centre is still centred in the crop.
        let centred = CGRect(x: 0.35, y: 0.15, width: 0.30, height: 0.25)
        let mapped = PublishCrop.inCropSpace(centred, crop: feed)
        #expect(abs(mapped.midX - 0.5) < 1e-9)
        // Vertical is untouched — the feed crop is full-height.
        #expect(abs(mapped.minY - centred.minY) < 1e-9)
        // …but it occupies MORE of the published width than of the sensor width.
        #expect(mapped.width > centred.width)
    }

    @Test func aFaceNearTheFrameEdgeMapsOutsideTheCrop() {
        let feed = PublishCrop.feedRect
        let edge = CGRect(x: 0.02, y: 0.2, width: 0.14, height: 0.2)
        #expect(!feed.contains(CGPoint(x: edge.midX, y: edge.midY)))
    }
}
