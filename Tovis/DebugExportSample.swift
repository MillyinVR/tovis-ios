#if DEBUG
import AVFoundation
import CoreGraphics
import Foundation
import SwiftUI
import TovisKit
import UIKit

/// DEBUG ONLY — a synthetic before/after so the social export sheet can be
/// opened, looked at and screenshotted without a camera, a signed-in pro, a
/// booking, or a running local stack.
///
/// Reached by `SIMCTL_CHILD_TOVIS_DEBUG_OPEN_EXPORT=1`. It exists for the same
/// reason as `DebugSessionSeed` and `TOVIS_DEBUG_OPEN_PRACTICE`: on this machine
/// the simulator cannot be driven by synthetic taps, and a screen nobody can
/// reach is a screen that ships build-green and never once seen.
///
/// It supplies only the SOURCE PIXELS. The crop, the layout and the signature all
/// come from the real `SocialExportRenderer`, so a screenshot of this sheet is an
/// honest picture of what a pro's export will look like — the sample is fake, the
/// rendering is not.
enum DebugExportSample {
    /// A model already carrying an identity, so both tiers can be screenshotted.
    /// `TOVIS_DEBUG_EXPORT_TIER=free` shows the platform mark; anything else (the
    /// default) shows the member treatment.
    @MainActor
    static func model() -> ProMediaExportModel {
        let model = ProMediaExportModel()
        let environment = ProcessInfo.processInfo.environment
        model.applyDebugIdentity(
            tier: environment["TOVIS_DEBUG_EXPORT_TIER"] ?? "member",
            handle: environment["TOVIS_DEBUG_EXPORT_HANDLE"] ?? "toristyles"
        )
        return model
    }

    static func context() -> ProMediaExportContext {
        ProMediaExportContext(
            main: .bytes(jpeg(hair: 0.80, skin: 0.78)),
            focal: MediaFocalPoint(x: 0.5, y: 0.36),
            before: .bytes(jpeg(hair: 0.22, skin: 0.72)),
            beforeFocal: MediaFocalPoint(x: 0.5, y: 0.36)
        )
    }

    /// The VIDEO counterpart to `context()` — a synthetic local clip so
    /// `ProVideoExportSheet` can be opened the same way, via
    /// `SIMCTL_CHILD_TOVIS_DEBUG_OPEN_VIDEO_EXPORT=1`, with no camera, no
    /// session and no booking with an uploaded clip. `main` just needs a URL —
    /// `AVURLAsset`/`ClipVault.poster` read a local `file://` URL exactly the
    /// way they read a remote one, so this exercises the real render path.
    static func videoContext() async -> ProMediaExportContext {
        ProMediaExportContext(main: .remote(await synthesizeSampleClip()), isVideo: true)
    }

    /// A short, real, decodable clip — same falloff gradient as `jpeg(hair:
    /// skin:)` baked frame by frame, so the video sheet's preview has
    /// something worth looking at rather than a flat test swatch.
    private static func synthesizeSampleClip() async -> URL {
        let width = 720, height = 960, frameCount = 30, fps: Int32 = 15
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tovis-debug-sample-\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return url }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
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

        let frame = jpeg(hair: 0.80, skin: 0.78)
        let cgFrame = UIImage(data: frame)?.cgImage

        for i in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pixelBufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
            guard let pixelBuffer = pixelBufferOut else { continue }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                )
                if let cgFrame {
                    context?.draw(cgFrame, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// A 3:4 "portrait": a studio falloff behind a head-and-shoulders silhouette,
    /// bright top-left to deep shadow bottom-right — so the signature corner is
    /// judged over a dark field and the rest over a light one.
    private static func jpeg(hair: CGFloat, skin: CGFloat) -> Data {
        let size = CGSize(width: 900, height: 1200)
        let renderer = UIGraphicsImageRenderer(size: size, format: {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true
            return format
        }())

        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let gradient = CGGradient(colorsSpace: space, colors: [
                UIColor(white: 0.92, alpha: 1).cgColor,
                UIColor(white: 0.11, alpha: 1).cgColor,
            ] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: []
            )
            UIColor(white: hair, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 180, y: 120, width: 540, height: 670)).fill()
            UIColor(red: skin, green: skin * 0.80, blue: skin * 0.70, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 270, y: 240, width: 360, height: 430)).fill()
            UIColor(white: hair * 0.7, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 45, y: 870, width: 810, height: 580)).fill()
        }
        return image.jpegData(compressionQuality: 0.95) ?? Data()
    }
}

/// `videoContext()` is async (the sample clip has to be written before there's
/// a URL to hand `ProVideoExportSheet`), so `TOVIS_DEBUG_OPEN_VIDEO_EXPORT`'s
/// `fullScreenCover` presents this instead of the sheet directly — a brief
/// spinner while the clip synthesizes, then the real sheet, same render path
/// a live booking video would take.
struct DebugVideoExportHost: View {
    @State private var context: ProMediaExportContext?

    var body: some View {
        Group {
            if let context {
                ProVideoExportSheet(context: context, model: DebugExportSample.model())
            } else {
                ProgressView().tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.ignoresSafeArea())
            }
        }
        .task {
            guard context == nil else { return }
            context = await DebugExportSample.videoContext()
        }
    }
}
#endif
