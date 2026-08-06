import AVFoundation
import CoreGraphics
import Foundation
import Testing
import TovisKit
@testable import Tovis

// `SocialVideoExportRenderer` — the AVFoundation half of video export. Unlike
// `ClipVaultTests`' fake `.mov` (a text file with a `.mov` extension, fine for
// pure file-custody logic that never opens it), these need a REAL decodable
// clip: the renderer's whole job is running one through `AVAssetExportSession`,
// so a fake file would fail at the first track load rather than exercise
// anything. Synthesized here via `AVAssetWriter` rather than a bundled fixture
// — no binary asset to keep in the repo, and the flat colour makes "did the
// mark actually get drawn" trivial to read back in pixels.

private func mark(_ shows: Bool, signature: String? = "@tori") -> ExportWatermark {
    ExportWatermark(signature: signature, showsPlatformMark: shows, platformMark: "Tovis")
}

/// A short, flat mid-grey clip — solid colour so any pixel that ISN'T mid-grey
/// in the output came from the watermark, not from source content.
private func synthesizeClip(
    width: Int = 400, height: Int = 300, frameCount: Int = 10, fps: Int32 = 10
) async throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tovis-test-source-\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
    )
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    for i in 0..<frameCount {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard let pool = adaptor.pixelBufferPool else { break }
        var pixelBufferOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
        guard let pixelBuffer = pixelBufferOut else { continue }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            memset(base, 128, bytesPerRow * height)  // flat mid-grey, every channel
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
        throw SocialVideoExportRenderError.exportFailed
    }
    return url
}

/// Luminance 0…1 at a normalized TOP-LEFT position — same reading convention
/// `SocialExportRenderTests`' `Bitmap` uses in TovisKit, standalone here since
/// this is a different test target.
private func luma(of image: CGImage, atX x: CGFloat, y: CGFloat) -> CGFloat {
    let width = image.width, height = image.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    buffer.withUnsafeMutableBytes { raw in
        let context = CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    let px = min(max(Int(x * CGFloat(width)), 0), width - 1)
    let py = min(max(Int(y * CGFloat(height)), 0), height - 1)
    let i = (py * width + px) * 4
    return (CGFloat(buffer[i]) * 0.299 + CGFloat(buffer[i + 1]) * 0.587
        + CGFloat(buffer[i + 2]) * 0.114) / 255
}

private func frame(of url: URL, atSeconds seconds: Double) async throws -> CGImage {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
}

/// The largest luma difference between two frames anywhere in a normalized
/// TOP-LEFT region, sampled on a grid rather than at one fixed point — at this
/// test's frame size the signature is only a couple of PIXEL ROWS tall (a
/// point-size formula scaled to a 300px-tall test clip, not the 1080px+ a real
/// export uses), so a single hardcoded sample coordinate is one off-by-a-row
/// away from missing it entirely. A region scan finds it wherever it lands.
private func maxLumaDifference(
    _ a: CGImage, _ b: CGImage, xRange: ClosedRange<Double>, yRange: ClosedRange<Double>, steps: Int = 24
) -> CGFloat {
    var maxDiff: CGFloat = 0
    for xi in 0...steps {
        let x = xRange.lowerBound + (xRange.upperBound - xRange.lowerBound) * Double(xi) / Double(steps)
        for yi in 0...steps {
            let y = yRange.lowerBound + (yRange.upperBound - yRange.lowerBound) * Double(yi) / Double(steps)
            maxDiff = max(maxDiff, abs(luma(of: a, atX: x, y: y) - luma(of: b, atX: x, y: y)))
        }
    }
    return maxDiff
}

@Suite struct SocialVideoExportRendererTests {
    // 🔴 "Cap at source resolution" and "preserve the clip's own length" —
    // asserted on the actual exported asset, not on the renderer's intentions.
    @Test func rendersAtSourceResolutionAndKeepsTheClipSLength() async throws {
        let source = try await synthesizeClip(width: 400, height: 300, frameCount: 10, fps: 10)
        defer { try? FileManager.default.removeItem(at: source) }

        let out = try await SocialVideoExportRenderer.render(
            sourceURL: source, watermark: mark(true, signature: "@tori")
        )
        defer { try? FileManager.default.removeItem(at: out) }

        #expect(FileManager.default.fileExists(atPath: out.path))

        let outAsset = AVURLAsset(url: out)
        let outTrack = try #require(try await outAsset.loadTracks(withMediaType: .video).first)
        let outSize = try await outTrack.load(.naturalSize)
        #expect(Int(outSize.width.rounded()) == 400)
        #expect(Int(outSize.height.rounded()) == 300)

        let duration = try await outAsset.load(.duration)
        #expect(abs(duration.seconds - 1.0) < 0.2)  // 10 frames @ 10fps
    }

    // 🔴 The mark is really baked into the pixels, not attached as metadata
    // nobody sees — checked by comparing a MARKED render against an UNMARKED
    // one at the same instant, exactly like the image path's
    // `theSignatureIsDrawnAndOnlyInItsCorner` compares signed vs. bare. A flat
    // grey source makes this unambiguous: any difference IS the mark.
    @Test func theWatermarkIsBakedIntoFramesInTheCornerOnly() async throws {
        let source = try await synthesizeClip()
        defer { try? FileManager.default.removeItem(at: source) }

        let signed = try await SocialVideoExportRenderer.render(
            sourceURL: source, watermark: mark(true, signature: "@tori")
        )
        defer { try? FileManager.default.removeItem(at: signed) }
        let bare = try await SocialVideoExportRenderer.render(
            sourceURL: source, watermark: mark(false, signature: nil)
        )
        defer { try? FileManager.default.removeItem(at: bare) }

        let signedFrame = try await frame(of: signed, atSeconds: 0.3)
        let bareFrame = try await frame(of: bare, atSeconds: 0.3)

        // Somewhere in the signature's safe box, the mark changed something.
        let cornerDiff = maxLumaDifference(
            signedFrame, bareFrame, xRange: 0.6...1.0, yRange: 0.85...1.0
        )
        #expect(cornerDiff > 0.05, "nothing was drawn in the signature's corner")

        // The top half of the frame — the "picture" — is untouched either way.
        let pictureDiff = maxLumaDifference(
            signedFrame, bareFrame, xRange: 0.0...1.0, yRange: 0.0...0.5
        )
        #expect(pictureDiff < 0.02, "the signature leaked into the picture")
    }

    // An empty watermark (no handle, no business name, member drops the mark)
    // must leave every frame as flat as re-encoding the source alone would —
    // no stray ink from an overlay that thinks it has nothing to draw but
    // draws a rect anyway. Compared against the SOURCE's own re-read frame
    // rather than a hardcoded grey value: H.264 doesn't round-trip 8-bit RGB
    // levels exactly (video-range vs. full-range), so "128" in is not "128"
    // back out even with zero content drawn — what matters is that exporting
    // with an empty watermark doesn't shift the picture beyond that same
    // baseline codec noise.
    @Test func anEmptyWatermarkLeavesFramesAsFlatAsTheSource() async throws {
        let source = try await synthesizeClip()
        defer { try? FileManager.default.removeItem(at: source) }

        let out = try await SocialVideoExportRenderer.render(
            sourceURL: source, watermark: mark(false, signature: nil)
        )
        defer { try? FileManager.default.removeItem(at: out) }

        let sourceFrame = try await frame(of: source, atSeconds: 0.3)
        let outFrame = try await frame(of: out, atSeconds: 0.3)
        let diff = maxLumaDifference(
            sourceFrame, outFrame, xRange: 0.0...1.0, yRange: 0.0...1.0
        )
        #expect(diff < 0.05, "an empty watermark still changed the picture")
    }
}
