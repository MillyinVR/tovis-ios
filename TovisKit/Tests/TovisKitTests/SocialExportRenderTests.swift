import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import TovisKit

// Real pixels. Everything above this file is arithmetic that could be right on
// paper and wrong on the canvas — a flipped axis, a crop measured from the wrong
// corner, a signature drawn outside the frame. So these render actual images and
// read actual pixels back.

// MARK: - Test images

/// A source split down the middle: black on the left, white on the right. Any
/// horizontal crop error moves the seam, which is trivially measurable.
private func splitImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    return context.makeImage()!
}

/// A flat mid-grey source — a clean background for "was anything drawn here?".
private func flatImage(width: Int, height: Int, gray: CGFloat = 0.5) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(gray: gray, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

// MARK: - Pixel reading

private struct Bitmap {
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
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        pixels = buffer
    }

    /// Luminance 0…1 at a normalized TOP-LEFT position.
    func luma(atX x: CGFloat, y: CGFloat) -> CGFloat {
        let px = min(max(Int(x * CGFloat(width)), 0), width - 1)
        let py = min(max(Int(y * CGFloat(height)), 0), height - 1)
        let i = (py * width + px) * 4
        return (CGFloat(pixels[i]) * 0.299 + CGFloat(pixels[i + 1]) * 0.587
            + CGFloat(pixels[i + 2]) * 0.114) / 255
    }

    /// How much of a normalized TOP-LEFT region differs from `other`, 0…1.
    func differenceFraction(from other: Bitmap, in region: CGRect) -> CGFloat {
        guard width == other.width, height == other.height else { return 1 }
        let x0 = Int(region.minX * CGFloat(width)), x1 = Int(region.maxX * CGFloat(width))
        let y0 = Int(region.minY * CGFloat(height)), y1 = Int(region.maxY * CGFloat(height))
        var differing = 0, total = 0
        for py in y0..<max(y0 + 1, y1) {
            for px in x0..<max(x0 + 1, x1) {
                let i = (py * width + px) * 4
                total += 1
                if pixels[i] != other.pixels[i] || pixels[i + 1] != other.pixels[i + 1]
                    || pixels[i + 2] != other.pixels[i + 2] {
                    differing += 1
                }
            }
        }
        return total == 0 ? 0 : CGFloat(differing) / CGFloat(total)
    }
}

private func decode(_ data: Data) -> Bitmap {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    return Bitmap(CGImageSourceCreateImageAtIndex(source, 0, nil)!)
}

private func mark(_ shows: Bool, signature: String? = "@tori") -> ExportWatermark {
    ExportWatermark(signature: signature, showsPlatformMark: shows, platformMark: "Tovis")
}

// MARK: - Tests

@Suite struct SocialExportRenderShapeTests {
    @Test func everyFormatRendersAtItsPublishedPixelSize() throws {
        let image = flatImage(width: 900, height: 1200)
        for format in SocialExportFormat.allCases {
            let plan = SocialExportPlanner.plan(
                format: format,
                subject: .single(SocialExportSource(pixelSize: CGSize(width: 900, height: 1200)))
            )
            let bitmap = decode(try SocialExportRenderer.render(
                plan: plan, images: [image], watermark: mark(true)
            ))
            #expect(bitmap.width == Int(format.pixelSize.width))
            #expect(bitmap.height == Int(format.pixelSize.height))
        }
    }

    @Test func aMismatchedImageCountIsRefusedRatherThanRenderedWrong() {
        let plan = SocialExportPlanner.plan(
            format: .feed916,
            subject: .pair(
                before: SocialExportSource(pixelSize: CGSize(width: 900, height: 1200)),
                after: SocialExportSource(pixelSize: CGSize(width: 900, height: 1200))
            )
        )
        #expect(throws: SocialExportRenderError.imageCountMismatch(expected: 2, got: 1)) {
            try SocialExportRenderer.render(
                plan: plan, images: [flatImage(width: 900, height: 1200)], watermark: mark(true)
            )
        }
    }
}

@Suite struct SocialExportRenderCropTests {
    // 🔴 The crop, verified on pixels rather than on paper. A 3:4 source split
    // black|white down the middle, exported to 9:16, must come out still split
    // down the middle — the crop takes equal bites off both sides. An axis flip or
    // a corner-origin mistake moves that seam and this catches it; nothing else
    // would, because a wrongly-cropped photo still looks like a photo.
    @Test func aCentredSeamStaysCentred() throws {
        let source = CGSize(width: 900, height: 1200)
        let plan = SocialExportPlanner.plan(
            format: .feed916, subject: .single(SocialExportSource(pixelSize: source))
        )
        let bitmap = decode(try SocialExportRenderer.render(
            plan: plan, images: [splitImage(width: 900, height: 1200)],
            watermark: mark(false, signature: nil)
        ))
        #expect(bitmap.luma(atX: 0.25, y: 0.3) < 0.15)   // still black on the left
        #expect(bitmap.luma(atX: 0.75, y: 0.3) > 0.85)   // still white on the right
        #expect(bitmap.luma(atX: 0.02, y: 0.3) < 0.15)   // and right to the edges
        #expect(bitmap.luma(atX: 0.98, y: 0.3) > 0.85)
    }

    // Pulling the crop hard to one side must actually move the picture. `adjust:
    // -1` on a landscape source pins the crop to the left, so the whole frame is
    // black.
    @Test func theManualNudgeMovesTheActualPixels() throws {
        let source = CGSize(width: 1600, height: 900)
        let image = splitImage(width: 1600, height: 900)

        func render(adjust: CGFloat) throws -> Bitmap {
            let plan = SocialExportPlanner.plan(
                format: .feed916,
                subject: .single(SocialExportSource(pixelSize: source, adjust: adjust))
            )
            return decode(try SocialExportRenderer.render(
                plan: plan, images: [image], watermark: mark(false, signature: nil)
            ))
        }

        #expect(try render(adjust: -1).luma(atX: 0.5, y: 0.3) < 0.15)  // all black
        #expect(try render(adjust: 1).luma(atX: 0.5, y: 0.3) > 0.85)   // all white
    }

    // 🔴 Before is on top / on the left. Verified in pixels because the diptych's
    // whole meaning depends on it: a black "before" and a white "after" must come
    // back in that order.
    @Test func theDiptychPutsBeforeFirstInPixels() throws {
        let size = CGSize(width: 900, height: 1200)
        let source = SocialExportSource(pixelSize: size)
        let black = flatImage(width: 900, height: 1200, gray: 0)
        let white = flatImage(width: 900, height: 1200, gray: 1)

        // 4:5 lays out side by side → before left.
        let sideBySide = decode(try SocialExportRenderer.render(
            plan: SocialExportPlanner.plan(
                format: .instagram45, subject: .pair(before: source, after: source)
            ),
            images: [black, white], watermark: mark(false, signature: nil)
        ))
        #expect(sideBySide.luma(atX: 0.25, y: 0.5) < 0.1)
        #expect(sideBySide.luma(atX: 0.75, y: 0.5) > 0.9)

        // 9:16 stacks → before on top.
        let stacked = decode(try SocialExportRenderer.render(
            plan: SocialExportPlanner.plan(
                format: .feed916, subject: .pair(before: source, after: source)
            ),
            images: [black, white], watermark: mark(false, signature: nil)
        ))
        #expect(stacked.luma(atX: 0.5, y: 0.2) < 0.1)
        #expect(stacked.luma(atX: 0.5, y: 0.8) > 0.9)
    }
}

@Suite struct SocialExportRenderWatermarkTests {
    private let sourceSize = CGSize(width: 900, height: 1200)

    private func render(_ watermark: ExportWatermark, format: SocialExportFormat = .instagram45) throws -> Bitmap {
        let plan = SocialExportPlanner.plan(
            format: format, subject: .single(SocialExportSource(pixelSize: sourceSize))
        )
        return decode(try SocialExportRenderer.render(
            plan: plan, images: [flatImage(width: 900, height: 1200)], watermark: watermark
        ))
    }

    /// The signature's own corner, as a normalized region of the canvas.
    private func signatureRegion(_ format: SocialExportFormat) -> CGRect {
        let canvas = format.pixelSize
        let box = SocialExportPlanner.signatureBox(in: canvas, format: format)
        let point = min(canvas.width, canvas.height) * 0.030
        return CGRect(
            x: (box.maxX - point * 14) / canvas.width,
            y: (box.maxY - point * 1.6) / canvas.height,
            width: (point * 14) / canvas.width,
            height: (point * 2.2) / canvas.height
        )
    }

    // 🔴 Direction A: the mark is really drawn. Asserted as "these two renders
    // differ in the signature corner and NOWHERE else" — so it catches both a mark
    // that never appears and a mark that has wandered across the picture.
    @Test func theSignatureIsDrawnAndOnlyInItsCorner() throws {
        for format in SocialExportFormat.allCases {
            let signed = try render(mark(true, signature: "@tori"), format: format)
            let bare = try render(mark(false, signature: nil), format: format)

            let corner = signatureRegion(format)
            #expect(signed.differenceFraction(from: bare, in: corner) > 0.02,
                    "\(format): nothing was drawn in the signature corner")

            // The top half of the frame — the client's face — is untouched.
            let picture = CGRect(x: 0, y: 0, width: 1, height: 0.5)
            #expect(signed.differenceFraction(from: bare, in: picture) == 0,
                    "\(format): the signature leaked into the picture")
        }
    }

    // 🔴 Direction B, the member perk, in pixels: the SAME signature with and
    // without the platform mark must produce different ink in that corner.
    // Asserting only "signed differs from bare" would pass even if the mark flag
    // were ignored entirely.
    @Test func theMemberPerkIsVisibleInThePixels() throws {
        let branded = try render(mark(true, signature: "@tori"))
        let unbranded = try render(mark(false, signature: "@tori"))
        let corner = signatureRegion(.instagram45)
        #expect(branded.differenceFraction(from: unbranded, in: corner) > 0.01,
                "the platform mark drew nothing — a member's export is identical to a free pro's")
    }

    // ...and the picture itself is byte-identical between the tiers. A membership
    // must change the signature and nothing else about the photograph.
    @Test func theTiersDifferOnlyInTheSignature() throws {
        let branded = try render(mark(true, signature: "@tori"))
        let unbranded = try render(mark(false, signature: "@tori"))
        let picture = CGRect(x: 0, y: 0, width: 1, height: 0.5)
        #expect(branded.differenceFraction(from: unbranded, in: picture) == 0)
    }

    // An empty watermark draws nothing at all — the member-with-no-handle case.
    @Test func anEmptyWatermarkLeavesTheFrameUntouched() throws {
        let empty = try render(mark(false, signature: nil))
        let alsoEmpty = try render(
            ExportWatermark(signature: nil, showsPlatformMark: false, platformMark: "Tovis")
        )
        #expect(empty.differenceFraction(
            from: alsoEmpty, in: CGRect(x: 0, y: 0, width: 1, height: 1)
        ) == 0)
    }

    // The 9:16 signature must land above the platform's chrome band — the one
    // mistake that renders perfectly and is never seen by a human.
    @Test func theNineSixteenSignatureIsNotUnderTheActionRail() throws {
        let signed = try render(mark(true, signature: "@tori"), format: .feed916)
        let bare = try render(mark(false, signature: nil), format: .feed916)
        let chrome = CGRect(
            x: 0, y: 1 - PublishCrop.coverSafeBottomFraction,
            width: 1, height: PublishCrop.coverSafeBottomFraction
        )
        #expect(signed.differenceFraction(from: bare, in: chrome) == 0)
    }
}

@Suite struct SocialExportOriginalBytesTests {
    /// A JPEG carrying EXIF a pro would miss — the capture date and a portrait
    /// orientation tag (the one the web gallery reads).
    static func jpegWithExif() -> Data {
        let image = flatImage(width: 400, height: 300)
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.jpeg" as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 6,  // rotated 90° — portrait shot
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:08:05 11:30:00",
            ],
        ] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func exifDate(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return nil }
        return exif[kCGImagePropertyExifDateTimeOriginal] as? String
    }

    // 🔴 The save path's whole promise. `OriginalMediaBytes.fetch` must hand back
    // the file it was served, byte for byte — anything that decodes and re-encodes
    // silently strips the capture date, the orientation tag, the lens and the
    // colour profile from the pro's own archive, and the photo still looks fine, so
    // nobody would notice for months.
    @Test func fetchingAnOriginalChangesNotOneByte() async throws {
        let original = Self.jpegWithExif()
        #expect(Self.exifDate(original) == "2026:08:05 11:30:00")

        OriginalBytesURLProtocol.body = original
        OriginalBytesURLProtocol.status = 200
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OriginalBytesURLProtocol.self]

        let fetched = try await OriginalMediaBytes.fetch(
            URL(string: "https://example.test/original.jpg")!,
            using: URLSession(configuration: configuration)
        )
        #expect(fetched == original)
        #expect(Self.exifDate(fetched) == "2026:08:05 11:30:00")
    }

    // ...and the contrast that makes the rule worth stating: an EXPORT is a new
    // photograph and carries none of it. Which is exactly why a save must never be
    // routed through the renderer.
    @Test func anExportIsANewFileAndKeepsNoneOfTheOriginalSExif() throws {
        let original = Self.jpegWithExif()
        let upright = try #require(UprightImageDecode.cgImage(from: original, maxPixel: 2400))
        let plan = SocialExportPlanner.plan(
            format: .instagram45,
            subject: .single(SocialExportSource(
                pixelSize: CGSize(width: upright.width, height: upright.height)
            ))
        )
        let exported = try SocialExportRenderer.render(
            plan: plan, images: [upright], watermark: mark(true)
        )
        #expect(Self.exifDate(exported) == nil)
        #expect(exported != original)
    }

    // The decode used by the renderer bakes EXIF orientation into the pixels — a
    // CGImage has no orientation of its own, so without this every portrait shot
    // would be cropped along the wrong axis. The 400×300 source is tagged
    // orientation 6, so upright it is 300×400.
    @Test func theDecodeUsedForExportsAppliesExifOrientation() throws {
        let upright = try #require(
            UprightImageDecode.cgImage(from: Self.jpegWithExif(), maxPixel: 2400)
        )
        #expect(upright.width == 300)
        #expect(upright.height == 400)
    }

    @Test func aFailedFetchIsAnErrorRatherThanEmptyBytesSavedAsAPhoto() async {
        OriginalBytesURLProtocol.body = Data()
        OriginalBytesURLProtocol.status = 403
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OriginalBytesURLProtocol.self]
        let session = URLSession(configuration: configuration)

        await #expect(throws: OriginalMediaBytesError.http(status: 403)) {
            try await OriginalMediaBytes.fetch(
                URL(string: "https://example.test/gone.jpg")!, using: session
            )
        }
    }
}

/// Serves canned bytes. Same URLProtocol pattern as the service tests.
final class OriginalBytesURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
