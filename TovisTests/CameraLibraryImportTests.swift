import CoreImage
import Foundation
import Testing
import UIKit
@testable import Tovis

// The library route uploads with `contentType: "image/jpeg"` (the pipeline's
// default). If the bytes aren't actually a JPEG, the server refuses them — and
// a refusal is precisely the dead end this whole chain exists to get out of.
// So the transcode isn't a nicety: it's what makes the second door work.
@Suite struct CameraLibraryImportTests {

    /// Build a solid-colour image and encode it, the way a picker would hand
    /// over bytes that never went through our camera.
    ///
    /// `scale = 1` on purpose: the renderer otherwise inherits the device's
    /// scale, so a "300×400" request would really produce 900×1200 PIXELS — and
    /// pixels are the unit the downscaler and the byte budget both work in.
    private func sample(width: Int, height: Int, png: Bool = false) -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            UIColor(red: 0.4, green: 0.7, blue: 0.6, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            // A little structure so the encoder can't collapse it to nothing.
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 3, height: height))
        }
        return (png ? image.pngData() : image.jpegData(compressionQuality: 1.0))!
    }

    /// JPEG's own magic number. The declared content type has to be true.
    private func isJPEG(_ data: Data) -> Bool {
        data.count > 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF
    }

    @Test func pngBecomesJPEG() throws {
        let png = sample(width: 400, height: 500, png: true)
        #expect(!isJPEG(png))

        let out = try #require(CameraLibraryImport.transcodeToJPEG(png))
        #expect(isJPEG(out))
    }

    /// Already-JPEG input is re-encoded on purpose rather than passed through:
    /// pass-through would leave orientation, dimensions and byte count unbounded.
    @Test func jpegIsStillNormalized() throws {
        let jpeg = sample(width: 400, height: 500)
        let out = try #require(CameraLibraryImport.transcodeToJPEG(jpeg))
        #expect(isJPEG(out))
    }

    /// Long edge in PIXELS — the unit the downscaler works in.
    private func pixelLongEdge(_ data: Data) throws -> Int {
        let cg = try #require(UIImage(data: data)?.cgImage)
        return max(cg.width, cg.height)
    }

    @Test func oversizedImageIsDownscaledToTheLongEdgeBudget() throws {
        // Larger than the budget on both axes.
        let huge = sample(width: 6000, height: 4500)
        let out = try #require(CameraLibraryImport.transcodeToJPEG(huge))
        #expect(try pixelLongEdge(out) <= Int(CameraLibraryImport.maxPixel))
    }

    /// A smaller photo must not be upscaled — that would invent detail and
    /// inflate the upload for nothing.
    @Test func smallImageIsNotUpscaled() throws {
        let small = sample(width: 300, height: 400)
        let out = try #require(CameraLibraryImport.transcodeToJPEG(small))
        #expect(try pixelLongEdge(out) == 400)
    }

    /// The signing route rejects a declared size over its cap before a byte
    /// moves, so an import has to land under the budget here or not at all.
    @Test func outputFitsTheUploadBudget() throws {
        let huge = sample(width: 6000, height: 4500)
        let out = try #require(CameraLibraryImport.transcodeToJPEG(huge))
        #expect(out.count <= CameraLibraryImport.maxBytes)
    }

    /// The budget must stay under the server's 30MB `UPLOAD_MAX_BYTES` — this
    /// is the constant that keeps the two ends agreeing.
    @Test func budgetLeavesHeadroomUnderTheServerCap() {
        #expect(CameraLibraryImport.maxBytes < 30 * 1024 * 1024)
    }

    @Test func nonImageBytesAreRejectedRatherThanUploaded() {
        let notAnImage = Data("this is not a photograph".utf8)
        #expect(CameraLibraryImport.transcodeToJPEG(notAnImage) == nil)
    }

    /// `prepare` is the whole route: bytes in, uploadable JPEG + focal out.
    @Test func prepareReturnsUploadableBytes() async throws {
        let png = sample(width: 800, height: 1000, png: true)
        let prepared = try #require(await CameraLibraryImport.prepare(png))
        #expect(isJPEG(prepared.jpeg))
        // No face in a flat swatch, so no focal — and that's the honest answer,
        // not a failure: the feed's cover-crop simply stays centred.
        #expect(prepared.focal == nil)
    }

    @Test func prepareRejectsBytesThatArentAnImage() async {
        let result = await CameraLibraryImport.prepare(Data("nope".utf8))
        #expect(result == nil)
    }
}
