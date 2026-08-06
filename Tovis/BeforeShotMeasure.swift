// What the booking's own BEFORE shot measured — the targets the AFTER is
// coached toward.
//
// Before/after IS the product, and three of the four things that make a pair
// read as true were already handled: the ghost lines up the angle, the light
// stamp compares brightness and warmth, and the card/WB calibration persists
// per booking so the after inherits the before's colour.
//
// The fourth is the one the industry cites most and the app never measured:
// FRAMING PARITY. Shoot the before tight and the after loose and the brain
// reads "the after looks bigger because it *is* bigger" — not because the work
// is better. Every ingredient already existed (`PhotoQC` finds the before's
// face, `ReferenceLookAnalyzer` already derives a fill band from a picked
// photo, `CompositionCoach` already enforces one); nothing connected them for
// the booking's own before shot. This does.
//
// Nothing here is a guessed threshold: the target IS the before's own measured
// number, so the salon pass cannot invalidate it.
import CoreImage
import Foundation
import Vision

/// One before-reference, measured with exactly the eyes the live coach judges
/// with (`VisionDetect` / `FrameMath`).
struct BeforeShotStamp: Equatable, Sendable {
    /// Whole-image luma + warmth — the original light stamp.
    let luma: Double
    let warmth: Double
    /// The same two measured on the segmented BACKGROUND, subject excluded.
    /// Nil when no person was segmented or there was too little background.
    ///
    /// This is the pair the light matcher prefers. A dark-to-blonde colour
    /// service legitimately changes whole-image luma — that is the work — and
    /// the matcher used to tell the pro to "dim a touch" about a transformation
    /// that had succeeded.
    let backgroundLuma: Double?
    let backgroundWarmth: Double?
    /// How much of the frame the subject filled, and where their face sat.
    /// The after's framing target.
    let subjectFill: Double?
    let faceBounds: CGRect?
}

enum BeforeShotMeasure {
    /// Working resolution for the stamp. Larger than the old light-only stamp's
    /// 240 px because segmentation and face detection are now part of it.
    nonisolated static let workingMaxDim: CGFloat = 480

    /// Measure a before-reference's bytes. Nil when they don't decode.
    /// Runs off the caller's actor.
    static func measure(_ data: Data) async -> BeforeShotStamp? {
        await Task.detached(priority: .utility) {
            autoreleasepool { measureSync(data) }
        }.value
    }

    nonisolated private static func measureSync(_ data: Data) -> BeforeShotStamp? {
        guard let full = CIImage(data: data, options: [.applyOrientationProperty: true])
        else { return nil }
        let working = FrameMath.downscaled(full, maxDim: workingMaxDim)
        guard working.extent.width > 0, working.extent.height > 0 else { return nil }
        let context = FrameMath.context

        let luma = FrameMath.averageLuma(working, context: context)
        let rgb = FrameMath.averageRGB(working, context: context) ?? (0.5, 0.5, 0.5)

        // Stills are already upright after EXIF; the live path lands in the
        // same space via `.oriented(.right)` on the camera buffer.
        func handler() -> VNImageRequestHandler {
            VNImageRequestHandler(ciImage: working, options: [:])
        }
        let face = VisionDetect.largestFace(performing: handler())

        var fill: Double?
        var backgroundLuma: Double?
        var backgroundWarmth: Double?
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? handler().perform([request])
        if let maskBuffer = request.results?.first?.pixelBuffer,
           let seg = FrameMath.segmentSignals(maskBuffer: maskBuffer, working: working,
                                              cropGuide: nil, context: context) {
            fill = seg.subjectFill
            backgroundLuma = seg.backgroundLuma
            backgroundWarmth = FrameMath.backgroundAverageRGB(
                working, background: seg.background, context: context
            ).map { FrameMath.warmth($0.rgb) }
        }

        return BeforeShotStamp(
            luma: luma, warmth: FrameMath.warmth(rgb),
            backgroundLuma: backgroundLuma, backgroundWarmth: backgroundWarmth,
            subjectFill: fill, faceBounds: face)
    }

    /// The fill band a shot should hold to match a measured one. ±`tolerance`
    /// around the reference's own number, clamped to a sane range — the same
    /// derivation "match a look" already used, in one place so the two can't
    /// drift into disagreeing about what "same framing" means.
    nonisolated static func fillBand(matching fill: Double, tolerance: Double = 0.12)
        -> ClosedRange<Double>? {
        guard fill > 0.02 else { return nil }
        let lower = max(0.05, fill - tolerance)
        let upper = min(0.98, fill + tolerance)
        guard lower < upper else { return nil }
        return lower...upper
    }
}

/// "Does the light still match the before?", as arithmetic.
///
/// Kept out of the camera view so the one thing that matters about it can be
/// tested: a colour service that legitimately changes the subject's brightness
/// must NOT read as a light change. Comparing whole frames, a dark-to-blonde
/// transformation moved the luma by more than the tolerance and the coach said
/// "Brighter than the before — dim a touch" about work that had succeeded.
enum LightMatch {
    /// One side of the comparison. `backgroundLuma`/`backgroundWarmth` are the
    /// preferred pair; the whole-frame values are the fallback when a side had
    /// no segmentable subject.
    struct Reading: Equatable {
        let luma: Double
        let warmth: Double?
        let backgroundLuma: Double?
        let backgroundWarmth: Double?
    }

    /// Compare live against target. Background-scoped only when BOTH sides have
    /// a background reading — comparing a background luma against a whole-frame
    /// one would invent a mismatch out of nothing.
    ///
    /// `moment` is the stable tag a `CoachVoice` renders `label` from — see
    /// docs/design/camera-personality-packs.md §2.1. `label` itself stays the
    /// canonical Calm Mentor text (pinned by `LightMatchTests`); rendering
    /// happens downstream, at the call site that actually shows/speaks it.
    static func verdict(live: Reading, target: Reading, noun: String)
        -> (label: String, ok: Bool, moment: CoachMoment) {
        let scoped = live.backgroundLuma != nil && target.backgroundLuma != nil
        let liveLuma = (scoped ? live.backgroundLuma : nil) ?? live.luma
        let targetLuma = (scoped ? target.backgroundLuma : nil) ?? target.luma
        let targetWarmth = (scoped ? target.backgroundWarmth : nil) ?? target.warmth
        let liveWarmth = (scoped ? live.backgroundWarmth : nil) ?? live.warmth

        let dLuma = liveLuma - targetLuma
        // No warmth reading on either side → treat warmth as matched rather
        // than as a mismatch against a number we don't have.
        let dWarmth = (liveWarmth ?? targetWarmth ?? 0) - (targetWarmth ?? 0)

        // Normalize each axis by its tolerance so they compare fairly.
        let lumaSeverity = abs(dLuma) / CoachTuning.lightMatchLumaTolerance
        let warmthSeverity = abs(dWarmth) / CoachTuning.lightMatchWarmthTolerance
        if lumaSeverity <= 1, warmthSeverity <= 1 {
            return ("Light matches the \(noun)", true, .lightMatched)
        }
        if lumaSeverity >= warmthSeverity {
            return dLuma > 0
                ? ("Brighter than the \(noun) — dim a touch", false, .lightBrighterThan)
                : ("Darker than the \(noun) — add light", false, .lightDarkerThan)
        }
        return dWarmth > 0
            ? ("Warmer than the \(noun) — cool the light", false, .lightWarmerThan)
            : ("Cooler than the \(noun) — warm the light", false, .lightCoolerThan)
    }
}

extension BeforeShotStamp {
    var lightReading: LightMatch.Reading {
        LightMatch.Reading(luma: luma, warmth: warmth,
                           backgroundLuma: backgroundLuma, backgroundWarmth: backgroundWarmth)
    }
}

extension ShotExpectations {
    /// Re-target this shot's fill band at the booking's own before shot, so the
    /// after is framed like its pair rather than like the generic portrait band.
    ///
    /// Detail/macro steps are left alone (a close-up of the work has no framing
    /// pair to match), and so is a stamp that never found a subject.
    func matchingFraming(of stamp: BeforeShotStamp) -> ShotExpectations {
        guard !isDetail, let fill = stamp.subjectFill,
              let band = BeforeShotMeasure.fillBand(matching: fill) else { return self }
        return ShotExpectations(face: face, fillBand: band, isDetail: isDetail,
                                allowsClosedEyes: allowsClosedEyes, poseRules: poseRules)
    }
}
