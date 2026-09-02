import Foundation
import Testing
@testable import TovisKit

// `MediaDisplayCrop` is what every cover-cropping surface reads — the rect AND
// the focal remapped into it, together. These pin the same worked numbers web's
// `resolveDisplayCrop` tests use, and the VIDEO exclusion both platforms make.
//
// 🔴 The remap is the dangerous half: handing a cropping view the raw focal does
// not crash and does not look wrong in review, it just shows somebody's shoulder.

/// The smallest thing that conforms — so these test the RULE, not one model.
private struct Row: MediaCropDisplayable {
    var isVideo: Bool = false
    var cropRect: MediaCropRect?
    var focalPoint: MediaFocalPoint?
}

@Suite struct MediaDisplayCropTests {
    private static let workedCrop = MediaCropRect(x: 0.25, y: 0.1, w: 0.5, h: 0.4)!
    private static let storedFocal = MediaFocalPoint(x: 0.6, y: 0.2)!

    @Test func remapsTheFocalIntoCropSpace() throws {
        let display = Row(cropRect: Self.workedCrop, focalPoint: Self.storedFocal).displayCrop

        #expect(display.crop == Self.workedCrop)
        // (0.60, 0.20) on the uncropped frame → (0.70, 0.25) inside this rect.
        let focal = try #require(display.focal)
        #expect(abs(focal.x - 0.7) < 1e-9)
        #expect(abs(focal.y - 0.25) < 1e-9)
        // The stored focal must NOT survive unchanged — that is the whole bug.
        #expect(focal != Self.storedFocal)
    }

    @Test func excludesVideoTheSameWayWebDoes() throws {
        // A clip's rect would come from its poster frame and that is unbuilt on
        // both platforms; honouring it here alone puts one look in two shapes.
        let display = Row(
            isVideo: true,
            cropRect: Self.workedCrop,
            focalPoint: Self.storedFocal
        ).displayCrop

        #expect(display.crop == nil)
        // With no crop, crop space IS frame space, so the focal is untouched.
        #expect(display.focal == Self.storedFocal)
    }

    @Test func aRowWithNoRectIsTheFullFrameAndAnUnchangedFocal() {
        let display = Row(cropRect: nil, focalPoint: Self.storedFocal).displayCrop
        #expect(display.crop == nil)
        #expect(display.focal == Self.storedFocal)
    }

    @Test func centresWhenTheSubjectWasFramedOut() throws {
        // Face at x 0.9, crop stops at 0.75 → nothing sensible to anchor on, and
        // centring is the honest answer rather than clamping to an edge.
        let display = Row(
            cropRect: Self.workedCrop,
            focalPoint: MediaFocalPoint(x: 0.9, y: 0.3)!
        ).displayCrop

        #expect(display.crop == Self.workedCrop)
        #expect(display.focal == nil)
    }

    @Test func fullFrameIsTheEmptyPair() {
        #expect(MediaDisplayCrop.fullFrame.crop == nil)
        #expect(MediaDisplayCrop.fullFrame.focal == nil)
    }
}
