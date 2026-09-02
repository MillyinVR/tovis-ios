import CoreGraphics
import XCTest
@testable import TovisKit

/// The display geometry of the publish crop, pinned to the SAME numbers as web's
/// `lib/media/cropWindow.test.ts`. Two things are being held:
///
///  1. **The nil-crop reduction** — with no rect these are exactly
///     `.scaledToFill()` / `.scaledToFit()` with a focal anchor, which is what
///     lets `MediaFocalPoint.coverCrop` delegate here instead of repeating it.
///  2. **The worked example** — crop (0.25, 0.10, 0.50, 0.40), focal
///     (0.60, 0.20) → (0.70, 0.25) in crop space. Same on both platforms, so a
///     sign error cannot live on one side only.
final class LookFeedLayoutTests: XCTestCase {

    /// The worked crop, identical to `MediaCropRectTests` and web.
    private let workedCrop = MediaCropRect(x: 0.25, y: 0.1, w: 0.5, h: 0.4)!

    /// The Looks slide as measured on production at iPhone width.
    private let slide = CGSize(width: 393, height: 787)

    /// A real portfolio capture: 3024 × 4032 = 3:4, which is every look today.
    private let capture34 = CGSize(width: 3024, height: 4032)

    // MARK: - windowSize

    func testWindowSizeIsTheWholeSourceWithoutACrop() {
        XCTAssertEqual(LookFeedLayout.windowSize(crop: nil, natural: capture34), capture34)
    }

    func testWindowSizeScalesByTheRectExtentOnly() {
        let natural = CGSize(width: 1000, height: 1000)
        XCTAssertEqual(
            LookFeedLayout.windowSize(crop: workedCrop, natural: natural),
            CGSize(width: 500, height: 400)
        )

        // The ORIGIN never changes the size.
        let moved = MediaCropRect(x: 0.5, y: 0.6, w: 0.5, h: 0.4)!
        XCTAssertEqual(
            LookFeedLayout.windowSize(crop: moved, natural: natural),
            LookFeedLayout.windowSize(crop: workedCrop, natural: natural)
        )
    }

    // MARK: - The nil-crop reduction

    func testCoverOfALegacyCaptureThrowsAwayAThirdOfItsWidth() {
        let box = LookFeedLayout.windowBox(window: capture34, container: slide, fit: .cover)
        XCTAssertEqual(box.width, 590.25, accuracy: 1e-6)
        XCTAssertEqual(box.height, 787, accuracy: 1e-6)
        XCTAssertEqual(box.minX, -98.625, accuracy: 1e-6)
        XCTAssertEqual(box.minY, 0, accuracy: 1e-6)

        // 33% of the photograph is off-screen. That is the defect the letterbox
        // exists to remove.
        XCTAssertEqual(1 - slide.width / box.width, 0.3342, accuracy: 1e-4)
    }

    func testContainShowsTheWholeFrameAndLeavesTheBarsTheBackdropFills() {
        let box = LookFeedLayout.windowBox(window: capture34, container: slide, fit: .contain)
        XCTAssertEqual(box.width, 393, accuracy: 1e-6)
        XCTAssertEqual(box.height, 524, accuracy: 1e-6)
        XCTAssertEqual(box.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(box.minY, 131.5, accuracy: 1e-6)
        XCTAssertEqual(box.width / box.height, capture34.width / capture34.height, accuracy: 1e-6)
    }

    func testAnchorSpendsTheOverflowLikeObjectPosition() {
        let topLeft = LookFeedLayout.windowBox(
            window: capture34, container: slide, fit: .cover,
            focal: MediaFocalPoint(x: 0, y: 0)
        )
        XCTAssertEqual(topLeft.minX, 0, accuracy: 1e-6)

        let bottomRight = LookFeedLayout.windowBox(
            window: capture34, container: slide, fit: .cover,
            focal: MediaFocalPoint(x: 1, y: 1)
        )
        XCTAssertEqual(bottomRight.minX, slide.width - bottomRight.width, accuracy: 1e-6)

        // No focal is the same as an explicit centre.
        XCTAssertEqual(
            LookFeedLayout.windowBox(window: capture34, container: slide, fit: .cover),
            LookFeedLayout.windowBox(
                window: capture34, container: slide, fit: .cover,
                focal: MediaFocalPoint(x: 0.5, y: 0.5)
            )
        )
    }

    func testA916FrameNearlyFillsTheSlide() {
        let shotTall = CGSize(width: 1080, height: 1920)
        let box = LookFeedLayout.windowBox(window: shotTall, container: slide, fit: .contain)
        XCTAssertEqual(box.width, 393, accuracy: 1e-6)
        XCTAssertEqual(box.height, 698.667, accuracy: 1e-3)
        // 44pt of bar each side — the letterbox all but disappears once the
        // masked viewfinder (capture item 1) ships.
        XCTAssertEqual(box.minY, 44.167, accuracy: 1e-3)
    }

    func testDegenerateInputsGiveZeroRatherThanInfinity() {
        XCTAssertEqual(LookFeedLayout.windowBox(window: .zero, container: slide, fit: .contain), .zero)
        XCTAssertEqual(LookFeedLayout.windowBox(window: capture34, container: .zero, fit: .cover), .zero)
        XCTAssertEqual(LookFeedLayout.sourceBox(crop: workedCrop, windowBox: .zero), .zero)
    }

    /// `coverCrop` is now a thin shape-adapter over `windowBox`; this is the
    /// assertion that keeps the two from drifting apart again.
    func testCoverCropStillAgreesWithWindowBox() {
        let focal = MediaFocalPoint(x: 0.6, y: 0.2)!
        let layout = focal.coverCrop(imageSize: capture34, containerSize: slide)
        let box = LookFeedLayout.windowBox(window: capture34, container: slide, fit: .cover, focal: focal)

        XCTAssertEqual(layout.size.width, box.width, accuracy: 1e-9)
        XCTAssertEqual(layout.size.height, box.height, accuracy: 1e-9)
        XCTAssertEqual(layout.offset.width, box.minX, accuracy: 1e-9)
        XCTAssertEqual(layout.offset.height, box.minY, accuracy: 1e-9)
    }

    // MARK: - sourceBox

    func testSourceBoxIsTheBoxItselfWithoutACrop() {
        let size = CGSize(width: 393, height: 524)
        XCTAssertEqual(
            LookFeedLayout.sourceBox(crop: nil, windowBox: size),
            CGRect(origin: .zero, size: size)
        )
    }

    func testSourceBoxOversizesAndBackShiftsTheSource() {
        let box = LookFeedLayout.sourceBox(
            crop: workedCrop,
            windowBox: CGSize(width: 393, height: 314.4)
        )
        XCTAssertEqual(box.width, 786, accuracy: 1e-6)
        XCTAssertEqual(box.height, 786, accuracy: 1e-6)
        XCTAssertEqual(box.minX, -196.5, accuracy: 1e-6)
        XCTAssertEqual(box.minY, -78.6, accuracy: 1e-6)
    }

    func testSourceBoxKeepsTheSourceAspectRatioSoTheDrawCannotDistort() {
        let window = LookFeedLayout.windowSize(crop: workedCrop, natural: capture34)
        let box = LookFeedLayout.windowBox(window: window, container: slide, fit: .contain)
        let source = LookFeedLayout.sourceBox(crop: workedCrop, windowBox: box.size)

        XCTAssertEqual(
            source.width / source.height,
            capture34.width / capture34.height,
            accuracy: 1e-6
        )
    }

    // MARK: - The whole pipeline, on the shared worked example

    func testContainsTheCropWindowAndCentresIt() {
        let natural = CGSize(width: 1000, height: 1000)
        let window = LookFeedLayout.windowSize(crop: workedCrop, natural: natural)
        let box = LookFeedLayout.windowBox(window: window, container: slide, fit: .contain)

        XCTAssertEqual(box.width, 393, accuracy: 1e-6)
        XCTAssertEqual(box.height, 314.4, accuracy: 1e-6)
        XCTAssertEqual(box.minX, 0, accuracy: 1e-6)
        XCTAssertEqual(box.minY, 236.3, accuracy: 1e-6)
    }

    func testCoversTheSlideAnchoredOnTheCropSpaceFocal() {
        // 🔴 The dangerous step. The stored focal is measured on the UNCROPPED
        // frame; a cover fit inside the crop needs it re-expressed.
        let focal = MediaFocalPoint(x: 0.6, y: 0.2)!
        let inCrop = focal.inCropSpace(workedCrop)
        XCTAssertEqual(inCrop?.x ?? -1, 0.7, accuracy: 1e-9)
        XCTAssertEqual(inCrop?.y ?? -1, 0.25, accuracy: 1e-9)

        let natural = CGSize(width: 1000, height: 1000)
        let window = LookFeedLayout.windowSize(crop: workedCrop, natural: natural)
        let box = LookFeedLayout.windowBox(window: window, container: slide, fit: .cover, focal: inCrop)

        XCTAssertEqual(box.width, 983.75, accuracy: 1e-6)
        XCTAssertEqual(box.height, 787, accuracy: 1e-6)
        XCTAssertEqual(box.minX, -413.525, accuracy: 1e-6)
        XCTAssertEqual(box.minY, 0, accuracy: 1e-6)

        // Using the RAW focal would move the window 59pt — a face-width on this
        // slide. This is the assertion that fails if the remap is ever dropped.
        let wrong = LookFeedLayout.windowBox(window: window, container: slide, fit: .cover, focal: focal)
        XCTAssertEqual(abs(wrong.minX - box.minX), 59.075, accuracy: 1e-3)
    }
}
