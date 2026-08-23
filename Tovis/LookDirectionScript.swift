// Trigger-bound direction for an AI-enhanced match look (tovis-app #974).
//
// The look brief used to be a flat script the coach read in order — line 3
// followed line 2 because line 2 finished, not because of anything the client
// did. The server now binds each line to the coach state that should speak it
// (`directions`); this type is the app half: it turns the wire list into a
// script the engine can consult per coaching moment, so the line the model
// wrote for "they're too far away" is what gets said at the moment the lens
// actually sees that, in place of the generic correction.
//
// Pure and camera-free on purpose — the trigger vocabulary and the
// moment→trigger mapping are the two things most worth pinning in tests.
import Foundation
import TovisKit

/// The trigger vocabulary this build understands — mirrors
/// `DIRECTION_TRIGGER_KINDS` (tovis-app lib/pro/cameraShotPacks.ts). Server
/// vocabulary this build doesn't know is dropped HERE, at script build, never
/// at decode — the same forward-compat contract as pose-rule kinds.
enum LookDirectionTrigger: String, CaseIterable, Sendable {
    /// The shot just began — the opener (expression/mood), not a correction.
    case opening
    /// Subject fill below the step's band — they read too small in frame.
    case subjectTooFar
    /// Subject fill above the step's band — they're crowding the frame.
    case subjectTooClose
    /// The step needs their face and the lens doesn't see one.
    case faceMissing
    /// A blink on a shot that wants eyes open (read at capture QC — the live
    /// stream has no blink signal, so this speaks on the retake, not before).
    case eyesClosed
    /// One of the step's pose rules is unmet.
    case poseUnmet
    /// Every gate satisfied — the settle line, the last word before the shutter.
    case ready
}

/// A match look's direction lines, keyed by coach state. `.empty` (no AI
/// enhance, or a pre-trigger server) makes every lookup miss, so callers fall
/// back to the generic coaching lines without a separate "is this on" flag.
struct LookDirectionScript: Equatable, Sendable {
    static let empty = LookDirectionScript(wire: [])

    private var lines: [LookDirectionTrigger: String] = [:]

    /// Build from the wire brief. Unknown triggers and blank lines drop; the
    /// first usable line per trigger wins (the server already sends at most
    /// one per trigger, so "first" only matters against a misbehaving reply).
    init(wire: [ProLookBriefDirection]) {
        for direction in wire {
            guard let trigger = LookDirectionTrigger(rawValue: direction.trigger) else { continue }
            let line = direction.line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, lines[trigger] == nil else { continue }
            lines[trigger] = line
        }
    }

    var isEmpty: Bool { lines.isEmpty }

    func line(for trigger: LookDirectionTrigger) -> String? { lines[trigger] }

    /// The look-specific line that should replace a live coaching correction,
    /// or nil to let the generic line speak. Only moments whose meaning matches
    /// a trigger's server-side definition map — everything else (lighting,
    /// level, background, a clipped body…) keeps its generic coaching, because
    /// the model never wrote a line for those states:
    ///  - `compositionTooFar` / `compositionTooClose` — the step's fill band,
    ///    exactly what `subjectTooFar` / `subjectTooClose` are derived from.
    ///  - `compositionFaceRequired` — the `faceMissing` trigger.
    ///  - a `.pose` nudge with NO moment — the brief pose-rule tip (rule tips
    ///    carry no `CoachMoment`; `.poseClipped` is a body cut off at the frame
    ///    edge, which is NOT "the pose this shot calls for is unmet").
    func line(replacing nudge: CoachNudge) -> String? {
        guard !lines.isEmpty else { return nil }
        switch nudge.moment {
        case .compositionTooFar: return lines[.subjectTooFar]
        case .compositionTooClose: return lines[.subjectTooClose]
        case .compositionFaceRequired: return lines[.faceMissing]
        case nil where nudge.category == .pose: return lines[.poseUnmet]
        default: return nil
        }
    }
}
