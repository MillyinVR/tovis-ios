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
    case lighting, composition, sharpness, background, pose, level, color

    /// Relative importance in the readiness score + which fix to surface first.
    /// Follows the beauty-photography priority order: light is the whole ballgame,
    /// then tack-sharp focus, then color truth & framing & a level horizon, then
    /// background/pose. Color is make-or-break for beauty, so it carries real weight.
    var weight: Double {
        switch self {
        case .lighting: return 1.6
        case .sharpness: return 1.4
        case .color: return 1.1
        case .composition: return 1.0
        case .level: return 1.0
        case .background: return 0.8
        case .pose: return 0.6
        }
    }
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

/// One fundamental's live status, for the at-a-glance checklist HUD.
struct CoachStatus: Sendable, Equatable, Identifiable {
    let category: CoachCategory
    let score: Double
    /// The corrective tip, if this fundamental needs attention right now.
    let message: String?
    var id: String { category.rawValue }
}

/// The aggregated result for one analyzed frame.
struct CoachResult: Sendable {
    let readiness: Double         // 0…1 overall
    let nudge: CoachNudge?        // the single most important fix, if any
    let statuses: [CoachStatus]   // per-fundamental status for the checklist HUD
    // Average color of the center region — the sample for gray-card white balance.
    let centerR: Double
    let centerG: Double
    let centerB: Double
    /// Face center (upright, top-left normalized) — drives face-priority
    /// exposure metering. Nil when no face is in frame.
    let faceCenter: CGPoint?
    /// Whole-frame luma + warmth of this frame — the live side of the
    /// before/after light matcher (compared against the before's stamp).
    let frameLuma: Double
    let frameWarmth: Double?
}

/// Body-pose framing read for the current frame, present only when a human body is
/// confidently detected. Coordinates already resolved to the upright frame.
/// (Camera tilt is judged by `LevelCoach` from the device's gravity vector — far
/// more reliable than inferring it from the subject's shoulders.)
struct PoseSignal: Sendable {
    /// A confidently-detected joint sits hard against a frame edge → subject is
    /// being clipped.
    let edgeClipped: Bool
}

/// Color-of-light read for the frame. Mixed light (warm bulb + cool window) is the
/// #1 real-world beauty-photo killer; a strong green (fluorescent) or warm/yellow
/// (incandescent) cast misrepresents skin tone and the work. Daylight (~neutral) is
/// the target. All values from the frame's average color; no reference card.
struct ColorSignal: Sendable {
    /// Spread of warm↔cool across the frame, 0…~1 — high = mixed light sources.
    let mixed: Double
    /// Global green tint, signed (+green / −magenta). Strong + = fluorescent.
    let greenTint: Double
    /// Global warmth, signed (+warm/yellow / −cool/blue). Strong + = warm bulbs.
    let warmth: Double
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
    /// Fraction of the frame the subject (segmented person) fills, 0…1. Nil when no
    /// person is segmented (flat-lay / detail shots aren't nagged to "get closer").
    let subjectFill: Double?
    /// Body-pose framing read, when a human body is detected. Nil otherwise.
    let pose: PoseSignal?
    /// Device roll off level, in degrees (signed), from CoreMotion. Nil when motion
    /// is unavailable (e.g. the Simulator). Drives the level / horizon coaching.
    let deviceTilt: Double?
    /// Color-of-light read (mixed light / cast). Nil if it couldn't be measured.
    let color: ColorSignal?
    /// What the current directed shot should contain (nil = freeform shooting —
    /// judge like a generic portrait).
    let expectations: ShotExpectations?
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
            return CoachSignal(score: 0.35, message: "Light’s behind them — turn them to face the window")
        }
        if luma < CoachTuning.lumaTooDark {
            return CoachSignal(score: 0.3, message: "Too dark — move toward the light")
        }
        if luma > CoachTuning.lumaTooBright {
            return CoachSignal(score: 0.4, message: "Blown out — turn away from the bright light")
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
        let expects = ctx.expectations

        // Fill the frame — the #1 amateur mistake is standing too far back.
        // Judged against the current shot's band when the guide sets one
        // (a detail shot wants much more fill than a portrait), else the
        // global floor. Detail/macro shots skip the floor — partial subjects
        // are the point.
        if let fill = ctx.subjectFill {
            if let band = expects?.fillBand {
                if fill < band.lowerBound {
                    return CoachSignal(score: 0.5, message: "Move in closer — fill the frame")
                }
                if fill > band.upperBound {
                    return CoachSignal(score: 0.55, message: "Too tight — step back a touch")
                }
            } else if expects?.isDetail != true, fill < CoachTuning.minSubjectFill {
                return CoachSignal(score: 0.5, message: "Move in closer — fill the frame")
            }
        }

        // Face placement only when the face belongs in this shot: a stray
        // mirror face must not drive headroom rules on a back-of-cut.
        if expects?.face == .absent {
            return CoachSignal(score: 1.0, message: nil)
        }
        guard let face = ctx.faceBounds else {
            if expects?.face == .required {
                return CoachSignal(score: 0.6, message: "Frame their face for this shot")
            }
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
        // Detail/macro shots demand more: raise the bar so "sharp enough for a
        // portrait" doesn't pass for a close-up of the work.
        let factor = ctx.expectations?.isDetail == true ? CoachTuning.detailSharpnessFactor : 1
        if s < CoachTuning.sharpnessSoft * factor {
            return CoachSignal(score: 0.3, message: "Hold steady — shot looks soft")
        }
        if s < CoachTuning.sharpnessSlightlySoft * factor {
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
        // A detail/macro shot fills the frame with the work — whatever scraps of
        // background remain shouldn't be judged.
        guard ctx.expectations?.isDetail != true,
              let clutter = ctx.backgroundClutter else {
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

/// Judges body framing when a full(er) body is in shot: not clipping the subject at
/// an edge. Neutral for head-and-shoulders work (no pose). Camera tilt is judged
/// separately by `LevelCoach`.
struct PoseCoach: ShotCoach {
    let category: CoachCategory = .pose

    func evaluate(_ ctx: FrameContext) -> CoachSignal {
        guard let pose = ctx.pose else {
            return CoachSignal(score: 1.0, message: nil)
        }
        if pose.edgeClipped {
            return CoachSignal(score: 0.5, message: "Subject’s getting clipped — pull back")
        }
        return CoachSignal(score: 0.9, message: nil)
    }
}

// MARK: - Level

/// Judges whether the camera is held level, from the device's gravity vector (not
/// the subject) — the single most common reason a shot looks "off." Neutral when
/// motion is unavailable (Simulator) so it never blocks readiness there.
struct LevelCoach: ShotCoach {
    let category: CoachCategory = .level

    func evaluate(_ ctx: FrameContext) -> CoachSignal {
        guard let tilt = ctx.deviceTilt else {
            return CoachSignal(score: 1.0, message: nil)
        }
        let off = abs(tilt)
        if off > CoachTuning.tiltBadDegrees {
            // Sign convention may flip per device orientation — verify on hardware.
            let dir = tilt > 0 ? "right" : "left"
            return CoachSignal(score: 0.4, message: "Camera’s tilted \(dir) — straighten it")
        }
        if off > CoachTuning.tiltWarnDegrees {
            return CoachSignal(score: 0.7, message: "Almost level — straighten up")
        }
        return CoachSignal(score: 1.0, message: nil)
    }
}

// MARK: - Color (light quality / white balance)

/// Flags the light problems that wreck beauty color: mixed sources (the #1 culprit)
/// and a strong green/fluorescent or warm/yellow cast that misrepresents skin tone.
/// Neutral when it can't measure (no signal) so it never blocks readiness blindly.
struct ColorCoach: ShotCoach {
    let category: CoachCategory = .color

    func evaluate(_ ctx: FrameContext) -> CoachSignal {
        guard let color = ctx.color else { return CoachSignal(score: 1.0, message: nil) }

        // Mixed light first — it can't be fixed with one white-balance setting.
        if color.mixed > CoachTuning.mixedLightSpread {
            return CoachSignal(score: 0.45, message: "Mixed light — turn off the overheads")
        }
        if color.greenTint > CoachTuning.greenCastTint {
            return CoachSignal(score: 0.55, message: "Greenish light — switch to one clean source")
        }
        if color.warmth > CoachTuning.warmCastWarmth {
            return CoachSignal(score: 0.6, message: "Warm/yellow light — daylight reads truer")
        }
        // Small penalty for mild mixing; otherwise clean.
        let score = max(0.75, 1.0 - color.mixed)
        return CoachSignal(score: score, message: nil)
    }
}
