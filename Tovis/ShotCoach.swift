// The on-device "AI photographer" coach model. Each `ShotCoach` judges ONE aspect
// of the live frame (lighting, composition, …) and returns a 0–1 score + a plain-
// language fix. The engine aggregates them into a readiness value + the single
// most important tip. Pure + Sendable so they run on the camera's frame queue.
//
// Coaches: Lighting, Composition, Sharpness, Background, Pose. The `FrameContext`
// carries pre-computed signals so coaches don't each re-scan, and every perception
// threshold lives in `CoachTuning` (one file to adjust during device tuning).
import CoreGraphics

enum CoachCategory: String, Sendable {
    case lighting, composition, sharpness, background, pose
}

/// One coach's read on the current frame. `score` is 0 (bad) … 1 (great);
/// `message` is the corrective tip, present only when there's something to fix.
struct CoachSignal: Sendable {
    let score: Double
    let message: String?
}

/// A prioritized tip surfaced to the pro (chip / voice).
struct CoachNudge: Sendable, Equatable {
    let category: CoachCategory
    let message: String
}

/// The aggregated result for one analyzed frame.
struct CoachResult: Sendable {
    let readiness: Double         // 0…1 overall
    let nudge: CoachNudge?        // the single most important fix, if any
}

/// Body-pose framing read for the current frame, present only when a human body is
/// confidently detected. Coordinates already resolved to the upright frame.
struct PoseSignal: Sendable {
    /// Signed angle of the shoulder line off horizontal, in degrees (nil if both
    /// shoulders weren't found). Positive/negative just means which way it tilts.
    let shoulderTilt: Double?
    /// A confidently-detected joint sits hard against a frame edge → subject is
    /// being clipped.
    let edgeClipped: Bool
}

/// Pre-computed, orientation-corrected signals for the current frame. Coordinates
/// are normalized with origin TOP-LEFT (UIKit-style) so composition math is simple.
struct FrameContext: Sendable {
    /// Average luma of the whole frame, 0…1.
    let avgLuma: Double
    /// Largest detected face, normalized (top-left origin). Nil if none.
    let faceBounds: CGRect?
    /// Average luma inside the face region, if a face was found.
    let faceLuma: Double?
    /// Focus quality 0…1 (measured on the subject region when a face is present,
    /// else the whole frame). Low = soft / motion-blurred.
    let sharpness: Double
    /// Busy-ness of the area behind the subject, 0 (clean) … 1 (cluttered). Nil
    /// when no person is segmented, so non-portrait shots aren't nagged.
    let backgroundClutter: Double?
    /// Body-pose framing read, when a human body is detected. Nil otherwise.
    let pose: PoseSignal?
}

protocol ShotCoach: Sendable {
    var category: CoachCategory { get }
    func evaluate(_ ctx: FrameContext) -> CoachSignal
}

// MARK: - Lighting

/// Judges exposure + backlighting. The strongest, most reliable on-device signal.
struct LightingCoach: ShotCoach {
    let category: CoachCategory = .lighting

    func evaluate(_ ctx: FrameContext) -> CoachSignal {
        let luma = ctx.avgLuma

        // Backlit: subject noticeably darker than the overall scene.
        if let faceLuma = ctx.faceLuma,
           faceLuma < luma * CoachTuning.backlitFaceRatio,
           faceLuma < CoachTuning.backlitFaceMaxLuma {
            return CoachSignal(score: 0.35, message: "Subject’s backlit — turn them toward the light")
        }
        if luma < CoachTuning.lumaTooDark {
            return CoachSignal(score: 0.3, message: "Too dark — find more light")
        }
        if luma > CoachTuning.lumaTooBright {
            return CoachSignal(score: 0.4, message: "Too bright — ease off the light")
        }
        // Score falls off smoothly away from the ideal exposure.
        let dist = abs(luma - CoachTuning.lumaIdeal)
        let score = max(0.6, 1.0 - dist * CoachTuning.lumaFalloff)
        return CoachSignal(score: score, message: nil)
    }
}

// MARK: - Composition

/// Judges subject placement when a face is present (centering + headroom). Stays
/// neutral when there's no face so non-portrait services aren't nagged (pose +
/// saliency coaches cover those later).
struct CompositionCoach: ShotCoach {
    let category: CoachCategory = .composition

    func evaluate(_ ctx: FrameContext) -> CoachSignal {
        guard let face = ctx.faceBounds else {
            return CoachSignal(score: 1.0, message: nil)
        }

        let centerX = face.midX
        let topY = face.minY
        let midY = face.midY

        // Headroom: face too high (cramped top) or sitting too low.
        if topY < CoachTuning.minHeadroom {
            return CoachSignal(score: 0.45, message: "Leave a little headroom — lower the camera")
        }
        if midY > CoachTuning.maxSubjectLow {
            return CoachSignal(score: 0.5, message: "Raise the camera — subject’s too low")
        }
        // Horizontal placement: comfortable near center or a third.
        let nearCenter = abs(centerX - 0.5) < CoachTuning.centerTolerance
        let nearThird = abs(centerX - 0.33) < CoachTuning.thirdTolerance
            || abs(centerX - 0.67) < CoachTuning.thirdTolerance
        if !nearCenter && !nearThird {
            return CoachSignal(score: 0.55, message: "Center your subject")
        }

        // Reward good framing; small deviation → small penalty.
        let dx = min(abs(centerX - 0.5), abs(centerX - 0.33), abs(centerX - 0.67))
        let score = max(0.7, 1.0 - dx)
        return CoachSignal(score: score, message: nil)
    }
}

// MARK: - Sharpness

/// Flags soft / motion-blurred frames — the single most common reason a shot gets
/// thrown away. `sharpness` is pre-computed edge energy on the subject; this coach
/// only nags when a frame is clearly soft so it doesn't fight normal focus hunting.
struct SharpnessCoach: ShotCoach {
    let category: CoachCategory = .sharpness

    func evaluate(_ ctx: FrameContext) -> CoachSignal {
        let s = ctx.sharpness
        if s < CoachTuning.sharpnessSoft {
            return CoachSignal(score: 0.3, message: "Hold steady — shot looks soft")
        }
        if s < CoachTuning.sharpnessSlightlySoft {
            return CoachSignal(score: 0.6, message: "Tap to focus — a touch soft")
        }
        // Clearly sharp; reward it.
        return CoachSignal(score: min(1.0, 0.7 + s * 0.5), message: nil)
    }
}

// MARK: - Background

/// Rewards a clean backdrop. Stays neutral when no person is segmented (the signal
/// is nil) so flat-lay / detail shots aren't pushed toward an empty background.
struct BackgroundCoach: ShotCoach {
    let category: CoachCategory = .background

    func evaluate(_ ctx: FrameContext) -> CoachSignal {
        guard let clutter = ctx.backgroundClutter else {
            return CoachSignal(score: 1.0, message: nil)
        }
        if clutter > CoachTuning.clutterBusy {
            return CoachSignal(score: 0.5, message: "Busy background — find a cleaner backdrop")
        }
        let score = max(0.7, 1.0 - clutter)
        return CoachSignal(score: score, message: nil)
    }
}

// MARK: - Pose

/// Judges body framing when a full(er) body is in shot: level shoulders and not
/// clipping the subject at an edge. Neutral for head-and-shoulders work (no pose).
struct PoseCoach: ShotCoach {
    let category: CoachCategory = .pose

    func evaluate(_ ctx: FrameContext) -> CoachSignal {
        guard let pose = ctx.pose else {
            return CoachSignal(score: 1.0, message: nil)
        }
        if pose.edgeClipped {
            return CoachSignal(score: 0.5, message: "Subject’s getting clipped — pull back")
        }
        if let tilt = pose.shoulderTilt, abs(tilt) > CoachTuning.shoulderTiltDegrees {
            return CoachSignal(score: 0.6, message: "Level the camera — shoulders are tilted")
        }
        return CoachSignal(score: 0.9, message: nil)
    }
}
