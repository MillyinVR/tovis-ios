import Foundation
import ImageIO
import Testing
import UIKit
@testable import Tovis

// The byte budget is the single biggest reason session photos now arrive.
//
// 🔴 The bug it fixes, measured: the camera set `maxPhotoDimensions` to the
// sensor maximum and uploaded `photo.fileDataRepresentation()` untouched, and a
// library import was deliberately matched to it at 4032px. Production uploads
// from the app measured 3.1–3.2 MB each, against 645–909 KB from the web app.
// A dozen of those fired at once on a salon connection completed ZERO uploads in
// a 24-hour window. Bounding the bytes is what makes each one finish.
//
// These tests pin the bound itself, because nothing else can: the build is
// perfectly happy with a budget that does nothing.
@Suite struct UploadImageBudgetTests {

    /// A photo-shaped image with enough structure that the JPEG encoder can't
    /// collapse it to a few kilobytes and make the size assertions meaningless.
    ///
    /// `scale = 1` on purpose: the renderer otherwise inherits the device scale,
    /// so a "4032×3024" request would really produce three times that in PIXELS
    /// — and pixels are the unit the budget works in.
    private func sample(width: Int, height: Int) -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for row in 0..<40 {
                for column in 0..<40 {
                    UIColor(
                        hue: CGFloat((row * 40 + column) % 256) / 256,
                        saturation: 0.9, brightness: 0.85, alpha: 1
                    ).setFill()
                    context.fill(CGRect(
                        x: column * width / 40, y: row * height / 40,
                        width: width / 40 + 1, height: height / 40 + 1
                    ))
                }
            }
        }
        return image.jpegData(compressionQuality: 1.0)!
    }

    private func pixelSize(_ data: Data) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (
            try #require(properties[kCGImagePropertyPixelWidth] as? Int),
            try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        )
    }

    // MARK: - The bound

    @Test func boundsAFullSensorCaptureToTheLongEdgeBudget() throws {
        // Roughly what a modern iPhone hands back from a full-resolution capture.
        let out = try #require(UploadImageBudget.prepareSync(sample(width: 4032, height: 3024)))
        let size = try pixelSize(out)
        #expect(max(size.width, size.height) <= Int(UploadImageBudget.maxPixel))
    }

    @Test func keepsTheAspectRatio() throws {
        let out = try #require(UploadImageBudget.prepareSync(sample(width: 4032, height: 3024)))
        let size = try pixelSize(out)
        // 4:3 in, 4:3 out — a stretched before/after would be worse than a big one.
        let ratio = Double(size.width) / Double(size.height)
        #expect(abs(ratio - 4.0 / 3.0) < 0.02)
    }

    @Test func landsUnderTheByteTarget() throws {
        let out = try #require(UploadImageBudget.prepareSync(sample(width: 4032, height: 3024)))
        #expect(out.count <= UploadImageBudget.targetBytes)
    }

    /// The regression this whole change exists for: what leaves the phone must be
    /// a large fraction SMALLER than what the sensor produced.
    @Test func isSubstantiallySmallerThanTheFullSensorBytes() throws {
        let original = sample(width: 4032, height: 3024)
        let out = try #require(UploadImageBudget.prepareSync(original))
        #expect(out.count < original.count / 2)
    }

    @Test func doesNotUpscaleAnAlreadySmallPhoto() throws {
        let out = try #require(UploadImageBudget.prepareSync(sample(width: 800, height: 600)))
        let size = try pixelSize(out)
        #expect(size.width == 800)
        #expect(size.height == 600)
    }

    // MARK: - Shape of the output

    @Test func alwaysProducesJPEGBytes() throws {
        // The upload declares `image/jpeg`; bytes that aren't are a 415 refusal.
        let out = try #require(UploadImageBudget.prepareSync(sample(width: 1200, height: 900)))
        #expect(out.count > 3 && out[0] == 0xFF && out[1] == 0xD8 && out[2] == 0xFF)
    }

    @Test func returnsNilForBytesThatAreNotAnImage() {
        #expect(UploadImageBudget.prepareSync(Data("not an image".utf8)) == nil)
    }

    /// `CameraLibraryImport` must not keep a second, larger budget of its own —
    /// the import door and the shutter have to bound identically or the bug
    /// simply moves to whichever one was forgotten.
    @Test func isTheSameBudgetTheLibraryImportUses() {
        #expect(CameraLibraryImport.maxPixel == UploadImageBudget.maxPixel)
        #expect(CameraLibraryImport.maxBytes == UploadImageBudget.maxBytes)
    }
}
