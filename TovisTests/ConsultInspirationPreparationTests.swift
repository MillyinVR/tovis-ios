import CoreGraphics
import Foundation
import Testing
import TovisKit
import UIKit
@testable import Tovis

@Suite struct ConsultInspirationPreparationTests {
    /// Distinct vertical bands expose a crop that accidentally uses full-frame
    /// pixels. Synthetic pixels only; no client photographs in the test suite.
    private func fixture() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200), format: format).image { context in
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            context.cgContext.setFillColor(UIColor.blue.cgColor)
            context.cgContext.fill(CGRect(x: 200, y: 0, width: 200, height: 200))
        }
    }

    @Test func rejectsInvalidConfirmationInsteadOfUploadingFullFrame() async throws {
        let data = try #require(fixture().pngData())
        for rect in [
            CGRect(x: 0.9, y: 0, width: 0.2, height: 1),
            CGRect(x: 0, y: 0, width: 0, height: 1),
            CGRect(x: 0, y: 0, width: -0.5, height: 1),
            CGRect(x: CGFloat.nan, y: 0, width: 0.5, height: 1),
            CGRect(x: 1.0000001, y: 0, width: 0.0000001, height: 1),
        ] {
            #expect(await ConsultPhotoPreparation.confirmedInspirationJPEG(from: data, rect: rect) == nil)
        }
    }

    @Test func onlyConfirmedPixelsAreEncoded() async throws {
        let data = try #require(fixture().pngData())
        let jpeg = try #require(await ConsultPhotoPreparation.confirmedInspirationJPEG(
            from: data, rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        ))
        let image = try #require(UIImage(data: jpeg))
        #expect(image.size == CGSize(width: 200, height: 200))
        #expect(jpeg.count <= ConsultService.maximumPhotoBytes)
        let pixel = try centerPixel(image)
        #expect(pixel[2] > 220 && pixel[0] < 30)
    }

    @Test func corruptImageFailsClosed() async {
        #expect(await ConsultPhotoPreparation.confirmedInspirationJPEG(
            from: Data([1, 2, 3]), rect: CGRect(x: 0, y: 0, width: 1, height: 1)
        ) == nil)
    }

    @Test func confirmedCropKeepsTheUploadDimensionLimit() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 2000), format: format).image { _ in
            fixture().draw(in: CGRect(x: 0, y: 0, width: 4000, height: 2000))
        }
        let data = try #require(source.pngData())
        let jpeg = try #require(await ConsultPhotoPreparation.confirmedInspirationJPEG(
            from: data, rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        ))
        let image = try #require(UIImage(data: jpeg))
        #expect(image.size == CGSize(width: 1568, height: 1568))
        #expect(jpeg.count <= ConsultService.maximumPhotoBytes)
    }

    @Test func rotatedAndMirroredPixelsMatchTheUprightPreview() throws {
        let raw = try #require(fixture().cgImage)
        for orientation in [UIImage.Orientation.right, .left, .upMirrored, .rightMirrored] {
            let oriented = UIImage(cgImage: raw, scale: 1, orientation: orientation)
            let upright = try #require(ConsultPhotoPreparation.uprightCGImage(oriented))
            let rect = CGRect(x: 0.55, y: 0.1, width: 0.35, height: 0.35)
            let direct = try #require(ConsultPhotoPreparation.cut(oriented, to: rect))
            let reference = try #require(ConsultPhotoPreparation.cut(UIImage(cgImage: upright), to: rect))
            #expect(direct.size == reference.size)
            #expect(try centerPixel(direct) == centerPixel(reference))
        }
    }

    private func centerPixel(_ image: UIImage) throws -> [UInt8] {
        let source = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let didDraw = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(source, in: CGRect(x: -source.width / 2, y: -source.height / 2,
                                           width: source.width, height: source.height))
            return true
        }
        #expect(didDraw)
        return bytes
    }
}
