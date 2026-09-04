import CoreImage
import Testing
@testable import Tovis

// FrameMath is the shared CoreImage/geometry measurement math behind the live
// coach, PhotoQC, and the light matcher. The pure bits (warmth, head expansion)
// are exact; the CoreImage aggregates are checked on synthetic solid images.
@Suite struct FrameMathTests {
    private func solid(_ color: CIColor, _ rect: CGRect) -> CIImage {
        CIImage(color: color).cropped(to: rect)
    }

    @Test func warmthIsSignedByRedVsBlue() {
        #expect(FrameMath.warmth((r: 0.8, g: 0.5, b: 0.2)) > 0)   // warm
        #expect(FrameMath.warmth((r: 0.2, g: 0.5, b: 0.8)) < 0)   // cool
        #expect(abs(FrameMath.warmth((r: 0.5, g: 0.5, b: 0.5))) < 1e-9) // neutral
    }

    @Test func expandToHeadDoublesAndClampsToUnitSquare() {
        let r = FrameMath.expandToHead(CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2))
        #expect(abs(r.width - 0.4) < 1e-9)    // width ×2
        #expect(abs(r.height - 0.44) < 1e-9)  // height ×2.2
        #expect(abs(r.minX - 0.3) < 1e-9)
        #expect(abs(r.minY - 0.24) < 1e-9)    // minY - 0.3·faceHeight

        // A face in the corner clamps its expanded box to the frame.
        let corner = FrameMath.expandToHead(CGRect(x: 0, y: 0, width: 0.2, height: 0.2))
        #expect(corner.minX == 0)
        #expect(corner.minY == 0)

        // A big face saturates at the full unit square.
        let big = FrameMath.expandToHead(CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6))
        #expect(abs(big.width - 1.0) < 1e-9)
        #expect(abs(big.height - 1.0) < 1e-9)
    }

    @Test func averageRGBAndLumaOnSolidGray() throws {
        let image = solid(CIColor(red: 0.5, green: 0.5, blue: 0.5),
                          CGRect(x: 0, y: 0, width: 32, height: 32))

        let rgb = try #require(FrameMath.averageRGB(image, context: FrameMath.context))
        // A balanced gray keeps the channels roughly equal (gamma-agnostic check).
        #expect(abs(rgb.r - rgb.g) < 0.05)
        #expect(abs(rgb.g - rgb.b) < 0.05)

        let luma = FrameMath.averageLuma(image, context: FrameMath.context)
        #expect(luma > 0.2 && luma < 0.8)
    }

    @Test func averageRGBNilOnDegenerateExtentAndLumaFallsBack() {
        let empty = CIImage(color: .red).cropped(to: .zero)
        #expect(FrameMath.averageRGB(empty, context: FrameMath.context) == nil)
        #expect(FrameMath.averageLuma(empty, context: FrameMath.context) == 0.5)
    }

    @Test func cropReturnsFullImageOnDegenerateRectAndSubrectOtherwise() {
        let image = solid(.gray, CGRect(x: 0, y: 0, width: 100, height: 100))

        let full = FrameMath.crop(image, normalizedTopLeft: .zero)
        #expect(full.extent == image.extent)

        let sub = FrameMath.crop(image, normalizedTopLeft: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        #expect(abs(sub.extent.width - 50) < 0.5)
        #expect(abs(sub.extent.height - 50) < 0.5)
    }

    @Test func downscaledShrinksLargeKeepsSmall() {
        let large = solid(.gray, CGRect(x: 0, y: 0, width: 1000, height: 800))
        #expect(abs(FrameMath.downscaled(large, maxDim: 480).extent.width - 480) < 1.0)

        let small = solid(.gray, CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(FrameMath.downscaled(small, maxDim: 480).extent.width == 100)
    }

    // MARK: - The colour-of-light read on a skin-filled close-up (B3)

    private var frame: CGRect { CGRect(x: 0, y: 0, width: 64, height: 64) }

    /// A warm frame — what a face fills the viewfinder with, indoors or out.
    private var warmFrame: CIImage {
        solid(CIColor(red: 0.72, green: 0.48, blue: 0.24), frame)
    }

    /// A background-weight image: white = background, black = subject. `top`
    /// is the share of the frame's HEIGHT that is background.
    ///
    /// ⚠️ `top` is not the fraction `backgroundAverageRGB` reports. That
    /// fraction is the area mean read back through the render transfer curve,
    /// so a 5%-white strip measures far above 0.05. Only the two ends of the
    /// range are transfer-curve-independent, and those are what these tests
    /// use; the FLOOR itself is pinned separately, straight against
    /// `backgroundAverageRGB`'s own `minFraction` argument.
    private func backgroundWeight(top: Double) -> CIImage {
        solid(.white, frame)
            .cropped(to: CGRect(x: 0, y: 0, width: frame.width,
                                height: frame.height * top))
            .composited(over: solid(.black, frame))
            .cropped(to: frame)
    }

    @Test func colorSignalReadsTheBackgroundWhenThereIsEnoughOfIt() throws {
        let signal = try #require(FrameMath.colorSignal(
            warmFrame, background: backgroundWeight(top: 0.5),
            context: FrameMath.context))
        #expect(signal.backgroundScoped)
    }

    /// The floor itself: below `minFraction` there is not enough background to
    /// divide by, and the answer is no reading rather than an invented one.
    @Test func backgroundAverageIsNilBelowTheMinimumFraction() throws {
        let half = backgroundWeight(top: 0.5)
        let generous = try #require(FrameMath.backgroundAverageRGB(
            warmFrame, background: half, minFraction: 0.01,
            context: FrameMath.context))
        // …and the same image against a floor above what it measures.
        #expect(FrameMath.backgroundAverageRGB(
            warmFrame, background: half, minFraction: generous.fraction + 0.01,
            context: FrameMath.context) == nil)
    }

    /// The B3 defect: the subject fills the frame, `backgroundAverageRGB`
    /// refuses to read the scraps that are left, and the old code fell through
    /// to the whole frame — reporting the client's SKIN as a warm room, firing
    /// the warm-light line and pinning readiness at 0.6. Nil is the honest
    /// answer, and `ColorCoach` stays silent on it.
    @Test func colorSignalIsNilWhenTheSubjectFillsTheFrame() {
        #expect(FrameMath.colorSignal(warmFrame, background: backgroundWeight(top: 0),
                                      context: FrameMath.context) == nil)
        // Proof the nil is about the MASK and not the image: the same warm
        // frame with no mask at all is a flat-lay/detail shot, where the frame
        // legitimately IS the background — and it still reads warm there.
        let noMask = FrameMath.colorSignal(warmFrame, background: nil,
                                           context: FrameMath.context)
        #expect(noMask != nil)
        #expect(noMask?.backgroundScoped == false)
        #expect((noMask?.warmth ?? 0) > CoachTuning.warmCastWarmth)
    }
}
