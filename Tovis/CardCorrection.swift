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
import CoreImage
import Foundation
import TovisKit

enum CardScanner {
    /// One card read: every swatch + the neutral band, sampled from a captured
    /// photo. Values are gamma-encoded sRGB (the calibration math linearizes).
    struct Reading {
        let swatches: [RGB]
        let neutralBand: RGB
    }

    /// Sample the card from a captured JPEG. `cardRegion` is the upright,
    /// top-left-normalized frame rect the on-screen alignment box showed — the
    /// card is assumed to fill it. Nil when the bytes don't decode.
    static func read(jpeg: Data, cardRegion: CGRect) async -> Reading? {
        await Task.detached(priority: .userInitiated) {
            guard let full = CIImage(data: jpeg, options: [.applyOrientationProperty: true]) else {
                return nil
            }
            let card = FrameMath.crop(full, normalizedTopLeft: cardRegion)
            func sample(_ rect: CGRect) -> RGB {
                let cell = FrameMath.crop(card, normalizedTopLeft: rect)
                let avg = FrameMath.averageRGB(cell, context: FrameMath.context) ?? (0.5, 0.5, 0.5)
                return RGB(avg.r, avg.g, avg.b)
            }
            return Reading(
                swatches: CardGeometry.swatchSampleRects().map(sample),
                neutralBand: sample(CardGeometry.wbSampleRect)
            )
        }.value
    }
}

enum CardCorrection {
    /// Bake a solved chromatic matrix into a captured JPEG. CIColorMatrix runs
    /// in CoreImage's linear working space — the same space the matrix was
    /// solved in (CameraCalibration linearizes before solving), so the two
    /// stay consistent. Returns nil on decode/render failure; callers fall
    /// back to the original bytes (an uncorrected photo beats a lost one).
    static func apply(_ matrix: ColorMatrix3x3, to jpeg: Data) async -> Data? {
        await Task.detached(priority: .userInitiated) {
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
        }.value
    }
}
