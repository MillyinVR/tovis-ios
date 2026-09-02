import Testing
import Foundation
import CoreGraphics
@testable import TovisKit

// The non-destructive publish crop (capture chain item 2) and — the part that
// actually matters — the focal remap into crop space.
//
// `MediaFocalPoint` is measured on the UNCROPPED frame. A view that displays
// only the crop window and reads the focal raw is off by the crop's origin,
// scaled by its extent. That failure does not crash, does not throw, and does
// not look wrong in a code review: it just posts somebody's shoulder. So the
// mapping is pinned with WORKED NUMBERS in both directions rather than
// round-trips, which a flipped sign can satisfy by cancelling itself out.
//
// The same worked numbers are pinned on the web side in
// `tovis-app/lib/media/cropRect.test.ts`, so the two implementations cannot
// drift apart silently.
@Suite struct MediaCropRectTests {

    // MARK: - Validation (mirrors web resolveCropRect)

    @Test func acceptsARectInsideTheFrame() {
        let crop = MediaCropRect(x: 0.25, y: 0.1, w: 0.5, h: 0.4)
        #expect(crop?.x == 0.25)
        #expect(crop?.w == 0.5)
    }

    @Test func acceptsTheFullFrame() {
        #expect(MediaCropRect(x: 0, y: 0, w: 1, h: 1) == MediaCropRect.fullFrame)
    }

    // 🔴 Three of four is not a degraded crop, it is an unanswerable one.
    @Test func rejectsAPartialRect() {
        #expect(MediaCropRect(x: nil, y: 0.1, w: 0.5, h: 0.4) == nil)
        #expect(MediaCropRect(x: 0.25, y: nil, w: 0.5, h: 0.4) == nil)
        #expect(MediaCropRect(x: 0.25, y: 0.1, w: nil, h: 0.4) == nil)
        #expect(MediaCropRect(x: 0.25, y: 0.1, w: 0.5, h: nil) == nil)
    }

    @Test func rejectsADegenerateOrOutOfFrameRect() {
        #expect(MediaCropRect(x: 0.25, y: 0.1, w: 0, h: 0.4) == nil)
        #expect(MediaCropRect(x: 0.25, y: 0.1, w: -0.5, h: 0.4) == nil)
        #expect(MediaCropRect(x: -0.1, y: 0.1, w: 0.5, h: 0.4) == nil)
        #expect(MediaCropRect(x: 0.7, y: 0.1, w: 0.5, h: 0.4) == nil)   // off the right
        #expect(MediaCropRect(x: 0.25, y: 0.7, w: 0.5, h: 0.4) == nil)  // off the bottom
    }

    @Test func rejectsNonFiniteCoordinates() {
        #expect(MediaCropRect(x: .nan, y: 0.1, w: 0.5, h: 0.4) == nil)
        #expect(MediaCropRect(x: 0.25, y: 0.1, w: .infinity, h: 0.4) == nil)
    }

    // MARK: - 🔴 The focal remap

    @Test func mapsAFocalToTheCropsOwnCentre() throws {
        // Crop covers x ∈ [0.25, 0.75], y ∈ [0.10, 0.50].
        // A face at (0.50, 0.30) is the crop's exact centre:
        //   x: (0.50 − 0.25) / 0.50 = 0.5
        //   y: (0.30 − 0.10) / 0.40 = 0.5
        let crop = try #require(MediaCropRect(x: 0.25, y: 0.1, w: 0.5, h: 0.4))
        let focal = try #require(MediaFocalPoint(x: 0.5, y: 0.3))
        let mapped = try #require(crop.focalInCropSpace(focal))

        #expect(abs(mapped.x - 0.5) < 1e-9)
        #expect(abs(mapped.y - 0.5) < 1e-9)
    }

    // The asymmetric case is the one that catches a sign flip: with a symmetric
    // crop, `(f − x) / w` and its mirror land on the same number.
    @Test func mapsAnOffCentreFocalToTheSameSideOfTheCrop() throws {
        // Crop x ∈ [0.20, 0.60] (w 0.40), y ∈ [0.00, 0.50] (h 0.50).
        // Face at (0.30, 0.40) sits LEFT of the crop's centre and LOW in it:
        //   x: (0.30 − 0.20) / 0.40 = 0.25
        //   y: (0.40 − 0.00) / 0.50 = 0.80
        let crop = try #require(MediaCropRect(x: 0.2, y: 0, w: 0.4, h: 0.5))
        let focal = try #require(MediaFocalPoint(x: 0.3, y: 0.4))
        let mapped = try #require(crop.focalInCropSpace(focal))

        #expect(abs(mapped.x - 0.25) < 1e-9)
        #expect(abs(mapped.y - 0.80) < 1e-9)
        // The invariant a sign error breaks: left of centre stays left of centre,
        // low stays low.
        #expect(mapped.x < 0.5)
        #expect(mapped.y > 0.5)
    }

    /// The SAME worked example the web suite pins, so the two sides cannot drift:
    /// crop (0.25, 0.10, 0.50, 0.40), focal (0.60, 0.20) → (0.70, 0.25).
    @Test func matchesTheWebWorkedExample() throws {
        let crop = try #require(MediaCropRect(x: 0.25, y: 0.1, w: 0.5, h: 0.4))
        let focal = try #require(MediaFocalPoint(x: 0.6, y: 0.2))
        let mapped = try #require(crop.focalInCropSpace(focal))

        #expect(abs(mapped.x - 0.70) < 1e-9)
        #expect(abs(mapped.y - 0.25) < 1e-9)
    }

    /// The mapping is `PublishCrop.inCropSpace` and nothing else — one
    /// implementation of the arithmetic, so a sign error cannot exist in one
    /// place and not the other.
    @Test func isExactlyPublishCropInCropSpace() throws {
        let crop = try #require(MediaCropRect(x: 0.25, y: 0.1, w: 0.5, h: 0.4))
        let focal = try #require(MediaFocalPoint(x: 0.6, y: 0.2))
        let mapped = try #require(crop.focalInCropSpace(focal))

        let direct = PublishCrop.inCropSpace(
            CGPoint(x: focal.x, y: focal.y),
            crop: crop.rect
        )
        #expect(abs(mapped.x - Double(direct.x)) < 1e-9)
        #expect(abs(mapped.y - Double(direct.y)) < 1e-9)
    }

    /// 🔴 The point of the whole exercise: the raw focal and the mapped focal
    /// are DIFFERENT for any crop that is not the full frame. A view that skips
    /// the remap is not "slightly off" — here it is 0.10 of the frame away
    /// horizontally and 0.05 vertically, which on a 9:16 feed card is a face vs.
    /// a shoulder. If a stub ever made `focalInCropSpace` the identity, this is
    /// the test that says so.
    @Test func theRemapIsNotTheIdentity() throws {
        let crop = try #require(MediaCropRect(x: 0.25, y: 0.1, w: 0.5, h: 0.4))
        let focal = try #require(MediaFocalPoint(x: 0.6, y: 0.2))
        let mapped = try #require(crop.focalInCropSpace(focal))

        #expect(abs(mapped.x - focal.x) > 0.05)
        #expect(abs(mapped.y - focal.y) > 0.02)
    }

    @Test func returnsNilWhenTheSubjectWasFramedOut() throws {
        // Face at x 0.9; the crop stops at 0.75, so there is nothing to centre on.
        let crop = try #require(MediaCropRect(x: 0.25, y: 0.1, w: 0.5, h: 0.4))
        let focal = try #require(MediaFocalPoint(x: 0.9, y: 0.3))
        #expect(crop.focalInCropSpace(focal) == nil)
    }

    @Test func clampsTheEpsilonSlackAtTheEdges() throws {
        // A focal exactly on the crop's bottom-right corner maps to (1, 1) —
        // never 1.0000000001, which MediaFocalPoint would reject outright.
        let crop = try #require(MediaCropRect(x: 0.25, y: 0.1, w: 0.5, h: 0.4))
        let focal = try #require(MediaFocalPoint(x: 0.75, y: 0.5))
        let mapped = try #require(crop.focalInCropSpace(focal))
        #expect(mapped.x == 1)
        #expect(mapped.y == 1)
    }

    // MARK: - The convenience on MediaFocalPoint

    @Test func withoutACropTheFocalIsUnchanged() throws {
        let focal = try #require(MediaFocalPoint(x: 0.42, y: 0.18))
        #expect(focal.inCropSpace(nil) == focal)
    }

    @Test func withTheFullFrameTheFocalIsUnchanged() throws {
        let focal = try #require(MediaFocalPoint(x: 0.42, y: 0.18))
        let mapped = try #require(focal.inCropSpace(.fullFrame))
        #expect(abs(mapped.x - 0.42) < 1e-9)
        #expect(abs(mapped.y - 0.18) < 1e-9)
    }

    // MARK: - Decoding (the wire contract)

    private func decodeTile(_ cropJSON: String) throws -> ProPortfolioTile {
        let json = """
        { "id": "m1", "lookId": "l1", "src": "https://x/y.jpg", "isVideo": false,
          "focalX": 0.6, "focalY": 0.2\(cropJSON) }
        """
        return try JSONDecoder().decode(ProPortfolioTile.self, from: Data(json.utf8))
    }

    @Test func decodesARectFromTheWire() throws {
        let tile = try decodeTile(#", "cropX": 0.25, "cropY": 0.1, "cropW": 0.5, "cropH": 0.4"#)
        let crop = try #require(tile.cropRect)
        #expect(crop.x == 0.25)
        #expect(crop.h == 0.4)
        // And the tile's cropping focal is the MAPPED one, not the raw wire pair.
        let inCrop = try #require(tile.focalPointInCrop)
        #expect(abs(inCrop.x - 0.70) < 1e-9)
        #expect(abs(inCrop.y - 0.25) < 1e-9)
        #expect(tile.focalPoint?.x == 0.6)
    }

    @Test func decodesAPayloadWithNoCropAtAll() throws {
        let tile = try decodeTile("")
        #expect(tile.cropRect == nil)
        // No crop → crop space IS frame space, so the focal passes through.
        #expect(tile.focalPointInCrop == tile.focalPoint)
    }

    @Test func aPartialRectOnTheWireDecodesToNoCrop() throws {
        let tile = try decodeTile(#", "cropX": 0.25, "cropY": 0.1, "cropW": 0.5"#)
        #expect(tile.cropX == 0.25)      // the raw field still decoded…
        #expect(tile.cropRect == nil)    // …but there is no usable rect.
        #expect(tile.focalPointInCrop == tile.focalPoint)
    }

    @Test func aNullRectOnTheWireDecodesToNoCrop() throws {
        let tile = try decodeTile(
            #", "cropX": null, "cropY": null, "cropW": null, "cropH": null"#
        )
        #expect(tile.cropRect == nil)
    }
}
