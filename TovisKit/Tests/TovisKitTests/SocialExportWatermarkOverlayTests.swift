import CoreGraphics
import Foundation
import Testing
@testable import TovisKit

// `SocialExportRenderer.watermarkOverlay` — the standalone signature-on-transparency
// render the video export path composites onto frames (see `SocialVideoExportRenderer`
// in the app target). Same signature-drawing code as the image path
// (`drawSignature`, shared by both), so these tests are about the ONE thing that
// differs from the image case: it draws onto real transparency rather than into a
// picture, and it has to actually BE transparent where nothing was drawn — a video
// overlay that isn't would paint a black rectangle over every frame.

private struct AlphaBitmap {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        let w = width, h = height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        pixels = buffer
    }

    /// Alpha 0…1 at a normalized TOP-LEFT position.
    func alpha(atX x: CGFloat, y: CGFloat) -> CGFloat {
        let px = min(max(Int(x * CGFloat(width)), 0), width - 1)
        let py = min(max(Int(y * CGFloat(height)), 0), height - 1)
        let i = (py * width + px) * 4
        return CGFloat(pixels[i + 3]) / 255
    }

    /// Whether any pixel in a normalized TOP-LEFT region has ink at all.
    func hasInk(in region: CGRect) -> Bool {
        inkPixelCount(in: region) > 0
    }

    /// How many pixels in a normalized TOP-LEFT region have ink at all — used
    /// where "more ink than the other render" is the assertion rather than "any
    /// ink", since the platform mark's exact position beside the signature isn't
    /// something a test should have to hardcode.
    func inkPixelCount(in region: CGRect) -> Int {
        let x0 = Int(region.minX * CGFloat(width)), x1 = Int(region.maxX * CGFloat(width))
        let y0 = Int(region.minY * CGFloat(height)), y1 = Int(region.maxY * CGFloat(height))
        var count = 0
        for py in y0..<max(y0 + 1, y1) {
            for px in x0..<max(x0 + 1, x1) where pixels[(py * width + px) * 4 + 3] > 0 {
                count += 1
            }
        }
        return count
    }
}

private func mark(_ shows: Bool, signature: String? = "@tori") -> ExportWatermark {
    ExportWatermark(signature: signature, showsPlatformMark: shows, platformMark: "Tovis")
}

@Suite struct SocialExportWatermarkOverlayTests {
    private let canvas = CGSize(width: 1080, height: 1920)

    // 🔴 The one failure mode that would silently ruin every video export: an
    // "empty" overlay that is actually an opaque black rectangle rather than real
    // transparency. Checked in alpha, not luma — a black rectangle and true
    // transparency can look identical composited over a black background.
    @Test func anEmptyWatermarkIsFullyTransparentNotAnOpaqueBlackFrame() throws {
        let image = try #require(SocialExportRenderer.watermarkOverlay(
            mark(false, signature: nil), canvasSize: canvas
        ))
        let bitmap = AlphaBitmap(image)
        #expect(bitmap.alpha(atX: 0.5, y: 0.5) == 0)
        #expect(bitmap.alpha(atX: 0.9, y: 0.95) == 0)
        #expect(bitmap.hasInk(in: CGRect(x: 0, y: 0, width: 1, height: 1)) == false)
    }

    @Test func aSignatureDrawsInkOnlyInTheBottomRightCorner() throws {
        let image = try #require(SocialExportRenderer.watermarkOverlay(
            mark(true, signature: "@tori"), canvasSize: canvas
        ))
        let bitmap = AlphaBitmap(image)

        let corner = CGRect(x: 0.5, y: 0.9, width: 0.5, height: 0.1)
        #expect(bitmap.hasInk(in: corner))

        // Nowhere near the top-left quadrant — the picture itself.
        let picture = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        #expect(bitmap.hasInk(in: picture) == false)
    }

    // The member perk must still show up here — this overlay is what the video
    // path signs with, so if the platform mark silently stopped drawing here the
    // membership page would be selling something video exports don't deliver.
    // Compared by ink COUNT over the whole signature corner rather than a
    // hand-picked sub-rect, since exactly where the mark lands beside the
    // signature (left or right of it) is layout detail this test shouldn't
    // have to assume.
    @Test func thePlatformMarkAddsInkBeyondTheSignatureAlone() throws {
        let signatureOnly = try #require(SocialExportRenderer.watermarkOverlay(
            mark(false, signature: "@tori"), canvasSize: canvas
        ))
        let withMark = try #require(SocialExportRenderer.watermarkOverlay(
            mark(true, signature: "@tori"), canvasSize: canvas
        ))
        let signatureBitmap = AlphaBitmap(signatureOnly)
        let markBitmap = AlphaBitmap(withMark)

        let corner = CGRect(x: 0.4, y: 0.85, width: 0.6, height: 0.15)
        #expect(markBitmap.inkPixelCount(in: corner) > signatureBitmap.inkPixelCount(in: corner))
    }

    // Point size scales with the canvas's short edge, same formula as the image
    // path — a bigger canvas gets a proportionally bigger mark, not a fixed one.
    @Test func theSignatureScalesWithCanvasSize() throws {
        let small = try #require(SocialExportRenderer.watermarkOverlay(
            mark(true, signature: "@tori"), canvasSize: CGSize(width: 270, height: 480)
        ))
        let large = try #require(SocialExportRenderer.watermarkOverlay(
            mark(true, signature: "@tori"), canvasSize: CGSize(width: 1080, height: 1920)
        ))
        #expect(small.width == 270)
        #expect(small.height == 480)
        #expect(large.width == 1080)
        #expect(large.height == 1920)
    }

    @Test func aDegenerateCanvasSizeReturnsNilRatherThanCrashing() {
        #expect(SocialExportRenderer.watermarkOverlay(mark(true), canvasSize: .zero) == nil)
    }
}
