import CoreGraphics
import Foundation
import SwiftUI
import Testing
import TovisKit
import UIKit
@testable import Tovis

@Suite struct ConsultPhotoFocusTests {
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
            #expect(await ConsultPhotoPreparation.confirmedCropJPEG(from: data, rect: rect) == nil)
        }
    }

    @Test func onlyConfirmedPixelsAreEncoded() async throws {
        let data = try #require(fixture().pngData())
        let jpeg = try #require(await ConsultPhotoPreparation.confirmedCropJPEG(
            from: data, rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        ))
        let image = try #require(UIImage(data: jpeg))
        #expect(image.size == CGSize(width: 200, height: 200))
        #expect(jpeg.count <= ConsultService.maximumPhotoBytes)
        let pixel = try centerPixel(image)
        #expect(pixel[2] > 220 && pixel[0] < 30)
    }

    @Test func corruptImageFailsClosed() async {
        #expect(await ConsultPhotoPreparation.confirmedCropJPEG(
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
        let jpeg = try #require(await ConsultPhotoPreparation.confirmedCropJPEG(
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

    /// 🔴 The whole frame is an answer on HER photo and on no other.
    ///
    /// An inspiration reference is asked for precisely so a region of it can be
    /// singled out — offering "use the whole photo" there would hand the vision
    /// read the group shot the focus step exists to prevent. The selfie is the
    /// opposite case: it is already a picture of her, so sending it as it is
    /// has to be one tap, and the crop is for the day someone else is in frame.
    @Test func onlyTheSelfieOffersTheWholePhoto() {
        #expect(ConsultPhotoFocusCopy.selfie.fullFrame == "Use the whole photo")
        #expect(ConsultPhotoFocusCopy.inspiration.fullFrame == nil)
    }

    /// Parity with web's `captureFocus`: the same words, in both places.
    @Test func selfieFocusSaysTheSameThingAsTheWeb() {
        #expect(ConsultPhotoFocusCopy.selfie.title == "Happy with this photo?")
        #expect(ConsultPhotoFocusCopy.selfie.center == "Zoom in on me")
        #expect(ConsultPhotoFocusCopy.selfie.confirm == "Use this area")
        #expect(ConsultPhotoFocusCopy.selfie.cancel == "Choose another photo")
    }
}

/// Draws the shipping focus sheet from a synthetic photo — no account, no API.
///
/// 🔴 The view itself, not a description of it. The web twin's equivalent check
/// caught a real defect (the whole-photo answer rendered disabled before the
/// image reported a size), which no assertion about the copy could have found.
@MainActor
@Suite struct ConsultPhotoFocusRenderTests {
    private func photo() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400), format: format).image { context in
            context.cgContext.setFillColor(UIColor.systemTeal.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        }
    }

    private func render(_ copy: ConsultPhotoFocusCopy, name: String) throws -> UIImage {
        // `.content`, not `body`: ImageRenderer draws a ScrollView blank, and a
        // blank PNG passes every assertion you would think to write about it.
        let renderer = ImageRenderer(content: ConsultPhotoFocusView(
            image: photo(), copy: copy, busy: false, onConfirm: { _ in }, onCancel: {}
        ).content.frame(width: 390).background(BrandColor.bgPrimary))
        renderer.scale = 2
        let image = try #require(renderer.uiImage)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tovis-focus-\(name).png")
        try #require(image.pngData()).write(to: url)
        print("FOCUS SNAPSHOT → \(url.path)")
        return image
    }

    /// Both cards draw, and the selfie's is TALLER by exactly the answer that
    /// only it has — the whole-photo button. A blank render (the ScrollView
    /// trap) fails this, because a blank page has no height to differ by.
    @Test func bothFocusCardsDrawAndOnlyTheSelfieOffersTheWholePhoto() throws {
        let selfie = try render(.selfie, name: "selfie")
        let inspiration = try render(.inspiration, name: "inspiration")
        #expect(selfie.size.width == 390)
        #expect(selfie.size.height > 400)
        #expect(selfie.size.height > inspiration.size.height)
    }
}
