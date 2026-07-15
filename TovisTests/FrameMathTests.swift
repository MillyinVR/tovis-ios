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
}
