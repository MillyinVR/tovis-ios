// The card-applied color pipeline: read the calibration card out of a captured
// frame (CardScanner) and bake the resulting chromatic correction into every
// captured JPEG before upload (CardCorrection) — so a pro's work reads the same
// color in a warm-bulb salon as in a daylight studio, in the portfolio and the
// Looks feed alike.
//
// Order of operations matters and is enforced by the scan flow in the camera
// view: white balance locks FIRST (from the card's neutral band), THEN the
// swatches are shot and solved — so the matrix corrects only the residual
// print/spectrum error and can't double-correct the cast. Exposure is anchored
// at the camera (EV bias from the band) because AE re-meters between the card
// shot and the subject shot. Math + geometry live in TovisKit CameraCalibration
// (pure, unit-tested); this file is the CoreImage glue.
import AVFoundation
import CoreImage
import Foundation
import TovisKit
import Vision

enum CardScanner {
    /// One card read: every swatch + the neutral band, sampled from a captured
    /// photo. Values are gamma-encoded sRGB (the calibration math linearizes).
    struct Reading {
        let swatches: [RGB]
        let neutralBand: RGB
    }

    /// Sample the card from a captured JPEG. The card is FOUND, not assumed:
    /// rectangle detection + perspective rectification locate it anywhere in
    /// frame (held at an angle, off-center — fine), falling back to the
    /// on-screen alignment box region (`cardRegion`, upright top-left
    /// normalized) when detection finds nothing. An upside-down card reverses
    /// the swatch order, so a read whose gray ramp doesn't validate is retried
    /// 180°-flipped (the neutral band is centered, so it's flip-immune either
    /// way). Nil when the bytes don't decode.
    static func read(jpeg: Data, cardRegion: CGRect) async -> Reading? {
        // Pooled: full-res Vision + CoreImage on a detached-task thread, same
        // reasoning as the live coach's per-frame pool.
        await Task.detached(priority: .userInitiated) {
            autoreleasepool { readSync(jpeg: jpeg, cardRegion: cardRegion) }
        }.value
    }

    private static func readSync(jpeg: Data, cardRegion: CGRect) -> Reading? {
        guard let full = CIImage(data: jpeg, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let card = detectAndRectify(full) ?? FrameMath.crop(full, normalizedTopLeft: cardRegion)
        guard let reading = sampleGrid(card) else { return nil }
        if CameraCalibration.looksLikeGrayRamp(measuredSRGB: reading.swatches) {
            return reading
        }
        let e = card.extent
        let flipped = card.transformed(by: CGAffineTransform(
            a: -1, b: 0, c: 0, d: -1,
            tx: e.minX + e.maxX, ty: e.minY + e.maxY))
        if let flippedReading = sampleGrid(flipped),
           CameraCalibration.looksLikeGrayRamp(measuredSRGB: flippedReading.swatches) {
            return flippedReading
        }
        // Neither orientation validates — hand back the unflipped read and
        // let the caller's gate reject it with a re-scan message.
        return reading
    }

    /// Find the card-shaped rectangle and warp it flat. Nil = no candidate.
    private static func detectAndRectify(_ image: CIImage) -> CIImage? {
        let request = VNDetectRectanglesRequest()
        // CR-80 short/long ≈ 0.63; leave slack for perspective foreshortening.
        request.minimumAspectRatio = 0.5
        request.maximumAspectRatio = 0.78
        request.minimumSize = 0.2          // the card should be a real chunk of frame
        request.minimumConfidence = 0.6
        request.maximumObservations = 3
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try? handler.perform([request])
        guard let best = request.results?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height
                < $1.boundingBox.width * $1.boundingBox.height
        }) else { return nil }

        // Vision corners are normalized bottom-left; CIPerspectiveCorrection
        // wants image-space points (also bottom-left) — scale by the extent.
        let e = image.extent
        func point(_ p: CGPoint) -> CIVector {
            CIVector(x: e.minX + p.x * e.width, y: e.minY + p.y * e.height)
        }
        return image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": point(best.topLeft),
            "inputTopRight": point(best.topRight),
            "inputBottomLeft": point(best.bottomLeft),
            "inputBottomRight": point(best.bottomRight),
        ])
    }

    /// Sample the swatch grid + neutral band from a flattened card image.
    private static func sampleGrid(_ card: CIImage) -> Reading? {
        guard card.extent.width > 8, card.extent.height > 8 else { return nil }
        func sample(_ rect: CGRect) -> RGB {
            let cell = FrameMath.crop(card, normalizedTopLeft: rect)
            let avg = FrameMath.averageRGB(cell, context: FrameMath.context) ?? (0.5, 0.5, 0.5)
            return RGB(avg.r, avg.g, avg.b)
        }
        return Reading(
            swatches: CardGeometry.swatchSampleRects().map(sample),
            neutralBand: sample(CardGeometry.wbSampleRect)
        )
    }
}

enum CardCorrection {
    /// Bake a solved chromatic matrix into a captured JPEG. CIColorMatrix runs
    /// in CoreImage's linear working space — the same space the matrix was
    /// solved in (CameraCalibration linearizes before solving), so the two
    /// stay consistent. Returns nil on decode/render failure; callers fall
    /// back to the original bytes (an uncorrected photo beats a lost one).
    static func apply(_ matrix: ColorMatrix3x3, to jpeg: Data) async -> Data? {
        // Pooled: the full-res render for the JPEG re-encode is the largest
        // transient in the whole capture path.
        await Task.detached(priority: .userInitiated) {
            autoreleasepool { applySync(matrix, to: jpeg) }
        }.value
    }

    private static func applySync(_ matrix: ColorMatrix3x3, to jpeg: Data) -> Data? {
        guard let image = CIImage(data: jpeg, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let m = matrix.m
        let corrected = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: m[0], y: m[1], z: m[2], w: 0),
            "inputGVector": CIVector(x: m[3], y: m[4], z: m[5], w: 0),
            "inputBVector": CIVector(x: m[6], y: m[7], z: m[8], w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let quality = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return FrameMath.context.jpegRepresentation(
            of: corrected, colorSpace: srgb, options: [quality: 0.95])
    }

    /// Bake the matrix into a recorded clip: re-export with a CoreImage
    /// composition applying the same CIColorMatrix per frame. Returns the
    /// corrected temp-file URL (caller deletes it after upload), nil on any
    /// failure — callers fall back to the original clip. Video color
    /// management is looser than stills (BT.709 vs sRGB primaries), so this is
    /// a close approximation, not colorimetric truth.
    static func applyToVideo(_ matrix: ColorMatrix3x3, at url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        let m = matrix.m
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let corrected = request.sourceImage.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: m[0], y: m[1], z: m[2], w: 0),
                "inputGVector": CIVector(x: m[3], y: m[4], z: m[5], w: 0),
                "inputBVector": CIVector(x: m[6], y: m[7], z: m[8], w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
            request.finish(with: corrected, context: FrameMath.context)
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            return nil
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("tovis-clip-corrected-\(UUID().uuidString).mov")
        export.videoComposition = composition
        export.outputURL = out
        export.outputFileType = .mov
        await export.export()
        guard export.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }
}
