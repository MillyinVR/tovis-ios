// What a slot SAYS when the same photo is refused twice — the iOS twin of
// web's lib/consult/captureRetakeGuidance.ts. Kept in TovisKit rather than the
// view so it can be tested without a screen.
//
// 🔴 Why this exists. On 2026-09-07 a client retook `face_front` and reported
// that the retake "never finished" — the slot showed Uploading, then went back
// to exactly what it showed before. The chain was in fact perfect: fresh keys,
// a fresh paid verdict on the new bytes, a fresh row. The screen simply showed
// no EVIDENCE that any of it had happened. A second refusal that is
// indistinguishable from the first reads as a broken app, not as an answer, and
// the client's next move is to press the same button again.

import Foundation

public struct ConsultSlotRetakeGuidance: Equatable, Sendable {
    /// "Attempt 3" — nil on a first refusal, where it would add nothing.
    public let attemptLabel: String?
    /// "This one's warm too." — only when the SAME finding refused the previous
    /// attempt. A different finding is progress, and "too" would be wrong.
    public let repeatedLine: String?
    /// What to try: the escalated lever on a repeat, otherwise the server's own
    /// tip for this frame.
    public let nextStep: String?
}

/// The short name of a finding, for the "this one's ___ too" sentence. Separate
/// from `consultQualityReasonMessage`, which is a whole explanation and cannot
/// be dropped into the middle of another sentence.
private func reasonShortName(_ code: String) -> String {
    switch code {
    case "WARM_INDOOR_LIGHT": return "warm"
    case "COLOR_CAST": return "tinted"
    case "VIEW_MISMATCH": return "the wrong view"
    case "HAIR_NOT_VISIBLE": return "missing the hair"
    case "SUBJECT_NOT_VISIBLE": return "missing the view"
    case "BLURRY": return "blurry"
    case "TOO_DARK": return "dark"
    case "TOO_BRIGHT": return "bright"
    default: return "not usable"
    }
}

/// A DIFFERENT next step for a finding that has now happened twice.
///
/// Deliberately not the model's retake tip. That tip is regenerated per call and
/// genuinely differs in wording each time — but it is advice about the SAME
/// thing, and a client who has just followed it needs a different lever, not the
/// same lever rephrased. These are the levers.
private func repeatNextStep(_ code: String) -> String? {
    switch code {
    case "WARM_INDOOR_LIGHT":
        return "Try again near a window in daylight — indoor bulbs are warmer than they look."
    case "COLOR_CAST":
        return "Try again near a window in daylight, away from coloured walls or a lit screen."
    case "VIEW_MISMATCH":
        return "This view is hard to get alone — try asking someone to take it for you."
    case "HAIR_NOT_VISIBLE":
        return "Try pulling your hair forward over one shoulder so it is fully in frame."
    case "SUBJECT_NOT_VISIBLE":
        return "Try asking someone to take this one for you, or use a mirror and the back camera."
    case "BLURRY":
        return "Try resting your phone against something steady, then tap the screen to focus before you shoot."
    case "TOO_DARK":
        return "Try turning on more light, or moving to a brighter room."
    case "TOO_BRIGHT":
        return "Try turning so the light falls ON you rather than behind you."
    default:
        return nil
    }
}

/// `attemptCount` includes THIS verdict, so a first refusal is 1 and the label
/// starts at 2.
public func consultSlotRetakeGuidance(
    reasonCode: String?,
    previousReasonCode: String?,
    retakeTip: String?,
    attemptCount: Int
) -> ConsultSlotRetakeGuidance {
    let repeated =
        reasonCode != nil
        && reasonCode != "PASS"
        && previousReasonCode == reasonCode
    return ConsultSlotRetakeGuidance(
        attemptLabel: attemptCount > 1 ? "Attempt \(attemptCount)" : nil,
        repeatedLine: repeated && reasonCode != nil
            ? "This one’s \(reasonShortName(reasonCode!)) too."
            : nil,
        nextStep: repeated && reasonCode != nil
            ? (repeatNextStep(reasonCode!) ?? retakeTip)
            : retakeTip
    )
}
