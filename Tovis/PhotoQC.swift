// Post-capture quality control — the photographer checking the back of the
// camera before the shot counts. The live coach predicts quality from a small
// preview frame; this verifies the ACTUAL captured image (sharpness, exposure,
// blinks) so a weak frame never reaches the portfolio / Looks feed unnoticed.
//
// Verdicts are deliberately lenient (only clearly failed frames flag) — QC is
// a safety net, not a second nag. Thresholds live in CoachTuning with the rest.
import CoreImage
import Foundation

struct PhotoQCReport: Sendable {
    /// Human phrasing of the single blocking problem; nil when the shot passes.
    let retakeReason: String?
    /// Normalized sharpness of the capture (same scale as the live coach).
    let sharpness: Double
    let luma: Double
    let eyesClosed: Bool
    var passed: Bool { retakeReason == nil }
}

enum PhotoQC {
    /// CIDetector face detection — old API, but the one on-device detector with
    /// per-eye closed flags (Vision has no blink signal).
    nonisolated(unsafe) private static let faceDetector = CIDetector(
        ofType: CIDetectorTypeFace,
        context: FrameMath.context,
        options: [CIDetectorAccuracy: CIDetectorAccuracyLow]
    )

    /// Evaluate a captured JPEG. `checkBlink: false` for shots where closed
    /// eyes are intended (lash work) or no face belongs in frame (back of cut).
    /// Runs the CoreImage/detector work off the caller's actor.
    static func evaluate(_ jpeg: Data, checkBlink: Bool = true) async -> PhotoQCReport {
        await Task.detached(priority: .userInitiated) {
            evaluateSync(jpeg, checkBlink: checkBlink)
        }.value
    }

    private static func evaluateSync(_ jpeg: Data, checkBlink: Bool) -> PhotoQCReport {
        guard let full = CIImage(data: jpeg, options: [.applyOrientationProperty: true]) else {
            // Unreadable bytes → don't block the flow; upload will surface it.
            return PhotoQCReport(retakeReason: nil, sharpness: 1, luma: 0.5, eyesClosed: false)
        }
        let working = FrameMath.downscaled(full, maxDim: CoachTuning.workingMaxDim)
        let luma = FrameMath.averageLuma(working, context: FrameMath.context)

        // Blink + face region (for subject-focused sharpness).
        var eyesClosed = false
        var faceRect: CGRect?
        if let detector = faceDetector {
            let faces = detector.features(in: working, options: [CIDetectorEyeBlink: true])
                .compactMap { $0 as? CIFaceFeature }
            if let face = faces.max(by: { $0.bounds.width < $1.bounds.width }) {
                // Both eyes closed = blink; one eye reads as a wink/angle and
                // false-positives too easily.
                eyesClosed = face.leftEyeClosed && face.rightEyeClosed
                let e = working.extent
                faceRect = CGRect(
                    x: (face.bounds.minX - e.minX) / e.width,
                    y: 1 - (face.bounds.maxY - e.minY) / e.height,   // CI bottom-left → top-left
                    width: face.bounds.width / e.width,
                    height: face.bounds.height / e.height
                )
            }
        }
        let sharpness = FrameMath.sharpness(working, subject: faceRect, context: FrameMath.context)

        let reason: String?
        if checkBlink, eyesClosed {
            reason = "Their eyes were closed"
        } else if sharpness < CoachTuning.qcSharpnessMin {
            reason = "It came out soft"
        } else if luma < CoachTuning.qcLumaMin {
            reason = "It came out too dark"
        } else if luma > CoachTuning.qcLumaMax {
            reason = "It came out blown out"
        } else {
            reason = nil
        }
        return PhotoQCReport(retakeReason: reason, sharpness: sharpness, luma: luma,
                             eyesClosed: eyesClosed)
    }
}
