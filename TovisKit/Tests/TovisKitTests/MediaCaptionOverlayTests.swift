import XCTest
@testable import TovisKit

final class MediaCaptionOverlayTests: XCTestCase {
    func testNilWhenThereIsNothingToShow() {
        XCTAssertNil(MediaCaptionOverlay.make(caption: nil, serviceNames: []))
    }

    func testBlankCaptionAndBlankTagsCollapseToNil() {
        // A whitespace-only caption must not render an empty panel over the photo.
        XCTAssertNil(MediaCaptionOverlay.make(caption: "   \n ", serviceNames: ["", "  "]))
    }

    func testCaptionOnly() {
        let overlay = MediaCaptionOverlay.make(caption: "  Soft glam  ", serviceNames: [])
        XCTAssertEqual(overlay?.caption, "Soft glam")
        XCTAssertEqual(overlay?.serviceNames, [])
    }

    func testServiceNamesOnlyStillRenders() {
        // Web shows the Services block for an untitled asset, so a tagged photo
        // with no caption must still produce a panel.
        let overlay = MediaCaptionOverlay.make(caption: nil, serviceNames: ["Balayage"])
        XCTAssertNil(overlay?.caption)
        XCTAssertEqual(overlay?.serviceNames, ["Balayage"])
    }

    func testTrimsDropsBlanksAndDeduplicates() {
        let overlay = MediaCaptionOverlay.make(
            caption: "Cut",
            serviceNames: ["  Balayage ", "   ", "Balayage", "Gloss"]
        )
        XCTAssertEqual(overlay?.serviceNames, ["Balayage", "Gloss"])
    }

    func testCapsChipsAtTheLimitPreservingOrder() {
        let names = (1...10).map { "Service \($0)" }
        let overlay = MediaCaptionOverlay.make(caption: nil, serviceNames: names)
        XCTAssertEqual(overlay?.serviceNames.count, MediaCaptionOverlay.chipLimit)
        XCTAssertEqual(overlay?.serviceNames.first, "Service 1")
        XCTAssertEqual(overlay?.serviceNames.last, "Service 6")
    }

    func testCapCountsDistinctNamesNotRawEntries() {
        // Seven entries, but one is a duplicate — the cap must not consume a slot
        // on the duplicate and silently drop a real seventh service.
        let overlay = MediaCaptionOverlay.make(
            caption: nil,
            serviceNames: ["A", "A", "B", "C", "D", "E", "F"]
        )
        XCTAssertEqual(overlay?.serviceNames, ["A", "B", "C", "D", "E", "F"])
    }
}
