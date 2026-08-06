// The video counterpart to `SocialExportRenderer` — signs a clip with the exact
// same watermark design, baked into every frame instead of one composited
// picture. Mirrors `CardCorrection.applyToVideo` (`CardCorrection.swift`)
// almost line for line: an `AVMutableVideoComposition(asset:)` per-frame
// handler, exported through `AVAssetExportSession`. The two things that make a
// SIGNED video export honest come for free from that shape rather than needing
// their own logic:
//
//   CAP AT SOURCE RESOLUTION — not setting `videoComposition.renderSize`
//   leaves it at the size this file computes from the asset's own track (its
//   natural size corrected for `preferredTransform`, the same orientation-
//   correction every AVFoundation caller needs for a portrait clip). Nothing
//   here ever upsamples.
//
//   PRESERVE AUDIO — the export session isn't restricted to a video-only
//   track, so the source's audio track passes through untouched.
//
// Crop/trim is out of scope for v1 (HANDOFF-camera-redesign.md follow-up): the
// clip ships at its own length and its own aspect, watermarked corner only.
import AVFoundation
import CoreImage
import Foundation
import TovisKit

enum SocialVideoExportRenderError: Error, Equatable {
    case noVideoTrack
    case exportSessionUnavailable
    case exportFailed
    /// A caller handed over a source that isn't a remote video URL — video
    /// export sources are always `.remote` today (see `ProMediaExportModel
    /// .renderVideoExport`), so this is a caller bug, not a real runtime case.
    case unsupportedSource
}

enum SocialVideoExportRenderer {
    /// Render a signed copy of the clip at `sourceURL` and return its temp-file
    /// URL (caller deletes it once shared/saved). `sourceURL` may be remote —
    /// `AVURLAsset` streams it the same way `FullscreenVideo`'s `AVPlayer`
    /// already does elsewhere in this file's app.
    static func render(sourceURL: URL, watermark: ExportWatermark) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SocialVideoExportRenderError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let corrected = naturalSize.applying(transform)
        let renderSize = CGSize(width: abs(corrected.width), height: abs(corrected.height))

        // Built ONCE, outside the per-frame handler — the mark is the same
        // image on every frame, and text layout is not something to redo
        // thousands of times over a clip.
        let overlay = SocialExportRenderer.watermarkOverlay(watermark, canvasSize: renderSize)
            .map(CIImage.init(cgImage:))

        let composition = AVMutableVideoComposition(asset: asset) { request in
            guard let overlay else {
                request.finish(with: request.sourceImage, context: FrameMath.context)
                return
            }
            request.finish(with: overlay.composited(over: request.sourceImage), context: FrameMath.context)
        }

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else { throw SocialVideoExportRenderError.exportSessionUnavailable }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("tovis-video-export-\(UUID().uuidString).mov")
        export.videoComposition = composition
        export.outputURL = out
        export.outputFileType = .mov
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw SocialVideoExportRenderError.exportFailed
        }
        return out
    }
}
