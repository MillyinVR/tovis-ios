import CoreGraphics
import Foundation
import Testing
@testable import TovisKit

// Camera C6c — the render side of the smart 9:16 crop. Proves:
//   1. `MediaFocalPoint.coverCrop` reproduces CSS `object-fit: cover` +
//      `object-position` (the web feed's rule): scale-to-cover size + a clamped
//      top-left offset that centers the window on the focal.
//   2. The look/board wire models decode `focalX`/`focalY` tolerantly and expose a
//      validated `focalPoint` (absent/out-of-range → nil → center).

@Suite struct FocalCoverCropTests {
    // MARK: - coverCrop geometry

    /// A 3:4 capture in the 9:16 feed → the image overflows HORIZONTALLY (the ~40%
    /// of width the blind center-crop throws away). The focal picks which slice.
    @Test func horizontalOverflowCoversHeightAndOffsetsWidth() throws {
        let image = CGSize(width: 300, height: 400)   // 3:4
        let container = CGSize(width: 90, height: 160) // 9:16
        let focal = try #require(MediaFocalPoint(x: 0.5, y: 0.5))

        let layout = focal.coverCrop(imageSize: image, containerSize: container)

        // scale = max(90/300, 160/400) = 0.4 → 120×160; height fills exactly.
        #expect(layout.size == CGSize(width: 120, height: 160))
        // Centered: (90 − 120)·0.5 = −15 horizontally, 0 vertically.
        #expect(layout.offset == CGSize(width: -15, height: 0))
    }

    @Test func focalZeroPinsTheLeadingEdge() throws {
        let focal = try #require(MediaFocalPoint(x: 0, y: 0))
        let layout = focal.coverCrop(
            imageSize: CGSize(width: 300, height: 400),
            containerSize: CGSize(width: 90, height: 160)
        )
        // object-position 0% 0% → top-left edges align → no shift.
        #expect(layout.offset == .zero)
    }

    @Test func focalOnePinsTheTrailingEdge() throws {
        let focal = try #require(MediaFocalPoint(x: 1, y: 0.5))
        let layout = focal.coverCrop(
            imageSize: CGSize(width: 300, height: 400),
            containerSize: CGSize(width: 90, height: 160)
        )
        // Full overflow to the left → right edge of the image at the right edge.
        #expect(layout.offset.width == -30) // (90 − 120)·1
        #expect(layout.offset.height == 0)
    }

    /// A landscape image in a wide container → the overflow flips to VERTICAL and
    /// the vertical focal drives the crop.
    @Test func verticalOverflowOffsetsHeight() throws {
        let focal = try #require(MediaFocalPoint(x: 0.5, y: 1))
        let layout = focal.coverCrop(
            imageSize: CGSize(width: 100, height: 100),   // square
            containerSize: CGSize(width: 200, height: 100) // 2:1
        )
        // scale = max(200/100, 100/100) = 2 → 200×200; width fills exactly.
        #expect(layout.size == CGSize(width: 200, height: 200))
        // Bottom-pinned: (100 − 200)·1 = −100 vertically, 0 horizontally.
        #expect(layout.offset == CGSize(width: 0, height: -100))
    }

    /// The offset never pushes the window past an image edge — the same clamp
    /// `object-position` enforces (because x/y are validated into [0,1]).
    @Test func offsetStaysWithinTheImageOnBothAxes() throws {
        let image = CGSize(width: 640, height: 480)
        let container = CGSize(width: 200, height: 300)
        for pair in [(0.0, 0.0), (0.5, 0.5), (1.0, 1.0), (0.13, 0.87)] {
            let focal = try #require(MediaFocalPoint(x: pair.0, y: pair.1))
            let layout = focal.coverCrop(imageSize: image, containerSize: container)
            // The window [0, container] must sit inside [0, scaled] on each axis.
            #expect(layout.offset.width <= 0.0001)
            #expect(layout.offset.height <= 0.0001)
            #expect(layout.offset.width + layout.size.width >= container.width - 0.0001)
            #expect(layout.offset.height + layout.size.height >= container.height - 0.0001)
        }
    }

    @Test func degenerateSizesFallBackToACenteredFill() throws {
        let focal = try #require(MediaFocalPoint(x: 0.4, y: 0.6))
        let container = CGSize(width: 120, height: 200)
        // A not-yet-measured (zero) image → fill the container, no offset.
        let layout = focal.coverCrop(imageSize: .zero, containerSize: container)
        #expect(layout.size == container)
        #expect(layout.offset == .zero)
    }

    // MARK: - Wire decode (LooksFeedItem)

    private func decodeLook(focalJSON: String) throws -> LooksFeedItem {
        let json = """
        {
          "id": "look_1",
          "url": "https://cdn.tovis/looks/1.jpg",
          "mediaType": "IMAGE",
          "createdAt": "2026-01-01T00:00:00Z",
          "_count": { "likes": 0, "comments": 0 },
          "viewerLiked": false,
          "viewerSaved": false,
          "viewerFollows": false\(focalJSON)
        }
        """
        return try JSONDecoder().decode(LooksFeedItem.self, from: Data(json.utf8))
    }

    @Test func looksFeedItemDecodesAValidFocal() throws {
        let item = try decodeLook(focalJSON: #", "focalX": 0.4, "focalY": 0.2"#)
        #expect(item.focalX == 0.4)
        #expect(item.focalPoint?.x == 0.4)
        #expect(item.focalPoint?.y == 0.2)
    }

    @Test func looksFeedItemWithoutFocalCentersItself() throws {
        let item = try decodeLook(focalJSON: "")
        #expect(item.focalX == nil)
        #expect(item.focalPoint == nil) // nil → center
    }

    @Test func looksFeedItemDropsAnOutOfRangeFocal() throws {
        // Decodes the raw number but the validated point rejects it → center.
        let item = try decodeLook(focalJSON: #", "focalX": 1.5, "focalY": 0.2"#)
        #expect(item.focalX == 1.5)
        #expect(item.focalPoint == nil)
    }

    // MARK: - Wire decode (PublicBoardLook)

    @Test func publicBoardLookDecodesAFocal() throws {
        let json = #"{ "id": "l1", "name": "Balayage", "imageUrl": "https://x/y.jpg", "focalX": 0.6, "focalY": 0.3 }"#
        let look = try JSONDecoder().decode(PublicBoardLook.self, from: Data(json.utf8))
        #expect(look.focalPoint?.x == 0.6)
        #expect(look.focalPoint?.y == 0.3)
    }

    @Test func publicBoardLookWithoutFocalCentersItself() throws {
        let json = #"{ "id": "l1", "name": "Balayage", "imageUrl": "https://x/y.jpg" }"#
        let look = try JSONDecoder().decode(PublicBoardLook.self, from: Data(json.utf8))
        #expect(look.focalPoint == nil)
    }
}
