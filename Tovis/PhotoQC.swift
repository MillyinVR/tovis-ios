// Post-capture quality control — the photographer checking the back of the
// camera before the shot counts. The live coach predicts quality from a small
// preview frame; this verifies the ACTUAL captured image (sharpness, exposure,
// blinks) so a weak frame never reaches the portfolio / Looks feed unnoticed.
//
// Verdicts are deliberately lenient (only clearly failed frames flag) — QC is
// a safety net, not a second nag. Thresholds live in CoachTuning with the rest.
import CoreImage
import Foundation
import TovisKit

nonisolated struct PhotoQCReport: Sendable {
    /// Human phrasing of the single blocking problem; nil when the shot passes.
    /// Canonical Calm Mentor text — unchanged by personality (see `retakeMoment`).
    let retakeReason: String?
    /// The stable tag a `CoachVoice` renders `retakeReason` from — nil exactly
    /// when `retakeReason` is nil. `retakeReason` itself never changes with
    /// personality; this only ever adds a render hook (docs/design/
    /// camera-personality-packs.md §2.1).
    let retakeMoment: CoachMoment?
    /// Interpolation for the moments whose canonical text has a `\(...)` in
    /// it (the QC subject noun, "It" / "Their face").
    let retakePhraseCtx: CoachPhraseContext?
    /// Normalized sharpness of the capture (same scale as the live coach).
    let sharpness: Double
    /// Whole-image luma.
    let luma: Double
    /// Luma inside the detected face — nil when no face was found. The exposure
    /// verdict is taken on THIS when it exists, for the same reason the live
    /// coach does: a whole-image gate offers a correctly-exposed close-up of
    /// deep skin (or any shot on a dark backdrop) as a retake for being "too
    /// dark", which is the one failure mode this camera can least afford.
    let faceLuma: Double?
    let eyesClosed: Bool
    /// Normalized top-left center of the largest detected face (camera C6),
    /// computed in the EXIF-corrected upright frame — nil when no face is found.
    /// Becomes the media's focal point so the full-screen Looks feed cover-crop
    /// centers on the subject. Because it's measured in the upright display frame,
    /// it maps 1:1 onto the browser / SwiftUI render regardless of whether the
    /// source JPEG carries EXIF orientation (manual still) or has it baked in
    /// (harvested still) — the parity the C6 design calls for.
    let focalPoint: CGPoint?
    var passed: Bool { retakeReason == nil }

    /// `retakeMoment`/`retakePhraseCtx` default to nil — a hand-written init
    /// (rather than in-line property defaults) so they still get a default
    /// value in the memberwise call while `evaluatePooled` can pass them
    /// explicitly. In-line defaults on stored `let`s drop the property from
    /// Swift's synthesized memberwise init entirely, which isn't what we want
    /// here (existing callers, e.g. `PhotoQCTests`, construct this directly).
    nonisolated init(retakeReason: String?, retakeMoment: CoachMoment? = nil, retakePhraseCtx: CoachPhraseContext? = nil,
                     sharpness: Double, luma: Double, faceLuma: Double?, eyesClosed: Bool, focalPoint: CGPoint?) {
        self.retakeReason = retakeReason
        self.retakeMoment = retakeMoment
        self.retakePhraseCtx = retakePhraseCtx
        self.sharpness = sharpness
        self.luma = luma
        self.faceLuma = faceLuma
        self.eyesClosed = eyesClosed
        self.focalPoint = focalPoint
    }
}

extension MediaFocalPoint {
    /// Build a wire focal from a normalized top-left face center (camera C6).
    /// nil center (no face detected) → nil focal → the server stores no focal →
    /// the feed cover-crop stays centered. Validation lives in the designated
    /// init (finite + within [0,1]), so a stray value can't reach the wire.
    init?(faceCenter: CGPoint?) {
        guard let c = faceCenter else { return nil }
        self.init(x: Double(c.x), y: Double(c.y))
    }
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

    /// Whether the largest face in an image reads as eyes-closed — used by the
    /// reference-look analyzer so a closed-eye reference (shimmer looks) doesn't
    /// get blink-blocked when the pro recreates it.
    nonisolated static func eyesClosedRead(in image: CIImage) -> Bool {
        guard let detector = faceDetector else { return false }
        let faces = detector.features(in: image, options: [CIDetectorEyeBlink: true])
            .compactMap { $0 as? CIFaceFeature }
        guard let face = faces.max(by: { $0.bounds.width < $1.bounds.width }) else { return false }
        return face.leftEyeClosed && face.rightEyeClosed
    }

    nonisolated private static func evaluateSync(_ jpeg: Data, checkBlink: Bool) -> PhotoQCReport {
        // Full-res CoreImage/detector work on a detached-task thread — pool it
        // so the autoreleased intermediates drain per evaluation (bursts run
        // several back-to-back), same reasoning as the live coach's pool.
        autoreleasepool { evaluatePooled(jpeg, checkBlink: checkBlink) }
    }

    nonisolated private static func evaluatePooled(_ jpeg: Data, checkBlink: Bool) -> PhotoQCReport {
        guard let full = CIImage(data: jpeg, options: [.applyOrientationProperty: true]) else {
            // Unreadable bytes → don't block the flow; upload will surface it.
            return PhotoQCReport(retakeReason: nil, sharpness: 1, luma: 0.5,
                                 faceLuma: nil, eyesClosed: false, focalPoint: nil)
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
        // Expose for the skin here too, on the same bands. Whole-image luma is
        // the room; when there's a face in the shot, the face is the exposure.
        let faceLuma = faceRect.map {
            FrameMath.averageLuma(FrameMath.crop(working, normalizedTopLeft: $0),
                                  context: FrameMath.context)
        }
        let exposure = faceLuma ?? luma
        let subject = faceLuma == nil ? "It" : "Their face"

        let reason: String?
        let moment: CoachMoment?
        let phraseCtx: CoachPhraseContext?
        let subjectCtx = CoachPhraseContext(subjectNoun: subject)
        if checkBlink, eyesClosed {
            reason = CoachCanonicalCopy.line(for: .qcEyesClosed)
            moment = .qcEyesClosed
            phraseCtx = nil
        } else if sharpness < CoachTuning.qcSharpnessMin {
            reason = CoachCanonicalCopy.line(for: .qcSoft)
            moment = .qcSoft
            phraseCtx = nil
        } else if exposure < CoachTuning.qcLumaMin {
            reason = CoachCanonicalCopy.line(for: .qcTooDark, ctx: subjectCtx)
            moment = .qcTooDark
            phraseCtx = subjectCtx
        } else if exposure > CoachTuning.qcLumaMax {
            reason = CoachCanonicalCopy.line(for: .qcBlownOut, ctx: subjectCtx)
            moment = .qcBlownOut
            phraseCtx = subjectCtx
        } else {
            reason = nil
            moment = nil
            phraseCtx = nil
        }
        // Focal = the center of the face rect (already normalized top-left in the
        // upright frame). object-position auto-clamps at the edges, so no clamping
        // is needed here; no face → nil → center.
        let focalPoint = faceRect.map { CGPoint(x: $0.midX, y: $0.midY) }
        return PhotoQCReport(retakeReason: reason, retakeMoment: moment, retakePhraseCtx: phraseCtx,
                             sharpness: sharpness, luma: luma,
                             faceLuma: faceLuma, eyesClosed: eyesClosed, focalPoint: focalPoint)
    }
}
