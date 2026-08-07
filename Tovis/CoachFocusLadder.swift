// Sequential focus coaching — founder-directed product change (2026-08-06 live
// device feedback): firing every broken fundamental's tip on top of the last
// overwhelmed the pro. The coach now locks onto ONE correction at a time, in a
// fixed big-adjustment-first order, and only moves to the next once the
// current one reads stable-good — "it's easier to mess up the small details
// after getting one right."
//
// This is a DECISION-layer change, done deliberately and once, for every
// personality equally — the §0 guardrail ("personalities never change advice,
// timing, or metering logic") still holds exactly: nothing here reads
// `CoachPersonality`/`CoachVoice`, and the ladder order + lock/advance/
// regression timing is identical no matter which pack is speaking. Only the
// STRING a pack renders for whichever moment the ladder is currently on ever
// varies — same seam as everywhere else, applied to a new decision.
import Foundation

/// The order the coach fixes things in, biggest adjustment first. Rationale,
/// rung by rung:
///
/// 1. **Lighting** — the single biggest determinant of whether a shot is
///    usable at all. Every other adjustment is provisional until the light is
///    right: recomposing a backlit or blown-out frame is wasted effort.
/// 2. **Color** — the other whole-frame, physical-environment problem (mixed
///    sources, a green cast, a too-warm white balance). Grouped right after
///    lighting because both are fixed by the same kind of move — changing
///    something about the ROOM, not the framing — before anything about the
///    subject's position is worth touching.
/// 3. **Framing (distance + presence)** — is there a valid, complete subject
///    in the shot at all, at roughly the right distance? Walking closer/
///    farther, or getting a face into frame, is a big physical adjustment
///    that has to happen before finer positioning is even meaningful to judge.
/// 4. **Centering** — headroom, vertical position, and horizontal centering.
///    The FINE polish once there's a valid subject at the right distance —
///    Tori's own example ("zoom out a bit to center the client better") is
///    exactly this rung, downstream of framing.
/// 5. **Level** — straightening the camera. A camera-HANDLING habit,
///    independent of where the subject is standing; smaller than
///    repositioning the subject, bigger than backdrop/pose polish.
/// 6. **Background** — the backdrop. Usually a small reposition, occasionally
///    a "move a few feet" fix — either way, scene polish once the subject
///    themselves is correctly framed and level.
/// 7. **Pose** — fine body-position compliance (clipped edges, a directed
///    pose brief). Detail-level, about how they're arranged within a frame
///    that's already right.
/// 8. **Sharpness / hold-still** — the final stability gate, right before the
///    shutter fires. Asking someone to hold still while the framing is still
///    being adjusted is backwards, so this is always last.
///
/// Composition splitting into two rungs (3 and 4) — rather than one — was the
/// one genuinely close call in this ordering: `CompositionCoach` is a single
/// category today. It's split here because Tori's own framing explicitly
/// distinguishes "distance/framing" from "centering" as two different steps,
/// and because they really are different-SIZED adjustments (walking vs a
/// small camera nudge). Flag if this reads wrong in practice — collapsing
/// them back to one `.framing` rung is a small change.
enum FocusRung: Int, CaseIterable, Sendable, Comparable {
    case lighting, color, framing, centering, level, background, pose, sharpness

    static func < (lhs: FocusRung, rhs: FocusRung) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension CoachMoment {
    /// Which rung this CORRECTION moment belongs to — nil for moments that
    /// aren't a ladder rung at all (good/passing moments, lane/QC/session
    /// copy, `dimensionCleared`). `PoseRule.tip` (server-driven, no moment)
    /// isn't listed here on purpose; it falls back to `CoachCategory.
    /// defaultFocusRung` at the call site, same as any other moment-less
    /// signal.
    var focusRung: FocusRung? {
        switch self {
        case .lightingBacklit, .lightingTooDark, .lightingBlownOut:
            return .lighting
        case .colorMixed, .colorGreenish, .colorWarm:
            return .color
        case .compositionTooFar, .compositionTooClose, .compositionFaceRequired:
            return .framing
        case .compositionOffFrame, .compositionNoHeadroom, .compositionTooLow, .compositionRecenter:
            return .centering
        case .levelTilted, .levelAlmostLevel:
            return .level
        case .backgroundBusy:
            return .background
        case .poseClipped:
            return .pose
        case .sharpnessHoldSteady, .sharpnessTapToFocus:
            return .sharpness
        default:
            return nil
        }
    }
}

extension CoachCategory {
    /// The rung a signal from this category falls on when it doesn't carry a
    /// specific `CoachMoment` (a server-driven pose-rule tip, say) — the
    /// broad per-category fallback. Composition normally resolves the finer
    /// framing/centering split via `CoachMoment.focusRung`; this is only the
    /// safety net for moment-less signals.
    var defaultFocusRung: FocusRung {
        switch self {
        case .lighting: return .lighting
        case .color: return .color
        case .composition: return .framing
        case .level: return .level
        case .background: return .background
        case .pose: return .pose
        case .sharpness: return .sharpness
        }
    }
}
