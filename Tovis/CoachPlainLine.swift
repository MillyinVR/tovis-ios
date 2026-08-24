// The plainest form of a correction the coach has already decided to give
// (camera plan P4.3, the wording half).
//
// `CoachBackOff` decides WHEN the coach has been saying the same thing for too
// long without the score moving. This is the other half of that step and it is
// kept deliberately apart from it: the DECISION to simplify is arithmetic and
// belongs at the rung, inside `CoachTipArbiter`; the WORDS are a substitution
// on a correction already chosen and belong here, at the same seam as
// `LookDirectionScript` (#974) and `CoachBookingVocabulary` (#358), applied in
// `CoachEngine.apply` and nowhere else.
//
// That seam matters for the same reason it did in #358: nothing in this file is
// visible from `ShotCoach`/`CoachAggregate`/`CoachTipArbiter`, so every pinned
// `CoachReadinessTests` assertion and the offline tuning bench keep measuring
// exactly today's canonical text.
//
// ## What "simpler" means here
//
// Almost every canonical correction is a pair: a DIAGNOSIS and an INSTRUCTION,
// joined by an em dash. "Mixed light — turn off the overheads." "Raise the
// camera — subject's too low." The diagnosis is what makes the line teach the
// first time; twenty seconds later the pro has read it, understood it, and is
// either working on it or can't. So the plain form keeps the instruction and
// drops everything else — including the spoken `why`, which the default voice
// appends and which is the longest thing in the utterance
// (`CoachVoice.includesWhy`).
//
// Which half is the instruction is NOT derivable — "Light's behind them — turn
// them to face the window" keeps its second clause, "Move in closer — fill the
// frame" keeps its first — so this is an explicit table, not a string split.
//
// A moment whose canonical line is ALREADY a single instruction has no plain
// form and returns nil: the coach says it once more unchanged, and then goes
// quiet on schedule. Simplification is a thing to do when there is something to
// take away, not a thing to be seen doing.
//
// ## Precedence, and the one deliberate limitation
//
// Look line → booking vocabulary → plain form. A look line is a bespoke
// sentence a model wrote for this specific shot; shortening it is not this
// layer's business, exactly as #359 withheld the room-memory offer from one.
// The booking's words run underneath, so the client is still named where the
// instruction is about them ("Center Maya", not "Center them").
//
// The `CoachMoment` is KEPT, same as `CoachBookingVocabulary` — so the plain
// form reaches Calm Mentor (the default voice, which defers to canonical text)
// and a pro on one of the four PACKS keeps their pack's own line. On a pack,
// stage one of the back-off is therefore a no-op in WORDS: what still happens
// there is the `why` being dropped from speech, and — the half that actually
// matters — the coach going quiet on schedule, which is decided at the rung and
// is entirely pack-independent. Teaching the packs a plain form is the same
// deliberate follow-up #358 recorded, not a silent side effect of this one.
import Foundation

/// The instruction, with everything that isn't the instruction taken off.
enum CoachPlainLine {
    /// The nudge in its plainest form when the coach has backed off, and
    /// exactly as it was otherwise — the whole of this layer's contribution to
    /// what the pro reads, in one call so it can be tested without an engine.
    ///
    /// The `CoachMoment` and the phrase context both survive: this only takes
    /// words off a line, and flattening a personality pack's flourish to do it
    /// would be the bad trade #358 already refused. Same shape, and the same
    /// name, as `CoachBookingVocabulary.applied(to:)`.
    static func applied(to nudge: CoachNudge, simplified: Bool,
                        vocabulary: CoachBookingVocabulary) -> CoachNudge {
        guard simplified, let plain = line(for: nudge, vocabulary: vocabulary) else { return nudge }
        return CoachNudge(category: nudge.category, message: plain,
                          moment: nudge.moment, phraseCtx: nudge.phraseCtx)
    }

    /// The plain form of `nudge`, or nil to say it once more exactly as it is.
    ///
    /// `vocabulary` is read only for the client's name — the four instructions
    /// whose object is the person in front of the lens read better naming them,
    /// and re-deriving a name here rather than asking the type that owns that
    /// derivation would be a second set of refusal rules to keep in step.
    static func line(for nudge: CoachNudge, vocabulary: CoachBookingVocabulary) -> String? {
        let ctx = nudge.phraseCtx ?? CoachPhraseContext()
        // "them" is the canonical coach's own word for the client (`ShotCoach`
        // says "turn them toward the light"), so this changes no vocabulary —
        // it only takes the booking's name when there is one.
        let who = vocabulary.clientName ?? "them"
        switch nudge.moment {
        // MARK: - Lighting
        //
        // ⚠️ `.lightingBacklit`, `.lightingTooDark` and `.lightingBlownOut` are
        // all `CoachSeverity.failure` at `LightingCoach`, and a hard failure is
        // never backed off (`CoachTipArbiter`), so these are unreachable today.
        // They are written anyway, and the enum is switched exhaustively-ish
        // through a default, because the severity of a moment is a tuning
        // decision one file away: the day a lighting condition is downgraded to
        // a correction, the coach should already know how to say it plainly
        // rather than jumping straight from the full sentence to silence.
        case .lightingBacklit:
            return "Turn \(who) to face the window"
        case .lightingTooDark:
            return ctx.namesAPerson ? "Turn \(who) toward the light" : "Move toward the light"
        case .lightingBlownOut:
            return "Turn away from the bright light"

        // MARK: - Colour (the room's light — the tips P4.1 can also retire)
        case .colorMixed:
            return "Turn off the overheads"
        case .colorGreenish:
            return "One clean light source"
        case .colorWarm:
            return "Daylight reads truer"

        // MARK: - Framing and centering
        case .compositionTooFar:
            return "Move in closer"
        case .compositionTooClose:
            return "Step back a touch"
        case .compositionOffFrame:
            return "Center \(who)"
        case .compositionNoHeadroom:
            return "Lower the camera"
        case .compositionTooLow:
            return "Raise the camera"
        case .compositionRecenter:
            // Canonical is already one clause ("Center them") — there
            // is nothing to take away, so this simplifies only when the booking
            // has a name to make it plainer WITH.
            return vocabulary.clientName.map { "Center \($0)" }

        // MARK: - Level, backdrop, pose, focus
        case .levelTilted:
            // The canonical line names the side it is tilted; the instruction
            // doesn't need it, and dropping it keeps this file clear of the
            // tilt SIGN convention `LevelCoach` still has flagged unverified.
            return "Straighten the camera"
        case .levelAlmostLevel:
            return "Straighten up"
        case .backgroundBusy:
            return "Find a cleaner backdrop"
        case .poseClipped:
            return "Pull back"
        case .sharpnessTapToFocus:
            return "Tap to focus"

        // `.compositionFaceRequired` ("Frame their face for this shot") is one
        // instruction already. `.sharpnessHoldSteady` is a hard failure and is
        // never backed off at all. Everything else here isn't a correction.
        default:
            return nil
        }
    }
}
