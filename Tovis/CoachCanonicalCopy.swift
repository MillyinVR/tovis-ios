// The canonical coach's words, in one place.
//
// `CalmMentorVoice` is the DEFAULT voice — the one every pro starts on — and
// it renders nothing: `phrase(for:ctx:)` returns nil for every moment, so the
// line the pro actually hears is the canonical `fallback` the call site hands
// `CoachVoiceRenderer`. That is deliberate and stays that way (see
// `CoachVoice.swift`): canonical sits at the BOTTOM of the vocabulary
// precedence `CoachEngine.apply` builds — look → booking → plain → room →
// canonical — and a voice that returned text would jump the whole stack.
//
// What was NOT deliberate is where those canonical strings lived. They were
// literals and runtime-interpolated fragments spread across eight files, which
// had two costs:
//
//   1. `scripts/coach-voice-manifest` could read all four opt-in packs and
//      only 7 of the default voice's 43 in-scope lines — the 7 that already
//      came from a table (`CoachCategory.canonicalGoodSentence`). A line the
//      manifest cannot see is a line that can never be pre-recorded, so the
//      library-voice upgrade could reach the packs nobody is on by default and
//      not the voice almost everyone hears.
//   2. Reading the default voice's register meant grepping eight files. A
//      slash spoken aloud by TTS, a drawer row label used as a sentence, an
//      impersonal noun and a stale fraction all shipped for months behind that
//      (iOS #363).
//
// This file is that one home. It is a MOVE: every string here came out of its
// old call site byte-for-byte, and each call site now READS this table rather
// than holding a second copy of the words — a parallel copy would be exactly
// the drift the manifest pipeline exists to prevent.
//
// Foundation only, on purpose. `scripts/coach-tuning-bench` and
// `scripts/coach-voice-manifest` both compile this file directly with
// `swiftc`; an `import TovisKit` or `import SwiftUI` here breaks both tools.
import Foundation

/// The default (Calm Mentor) text for a `CoachMoment` — the canonical line a
/// `CoachVoice` pack overrides and falls back to.
///
/// The signature deliberately mirrors `CoachVoice.phrase(for:ctx:)`. Canonical
/// is not a lesser thing the packs fall back into; it is the same rendering
/// question asked of the voice that ships turned on, and the tooling can now
/// ask it the same way.
nonisolated enum CoachCanonicalCopy {
    /// Moments whose text is composed at RUNTIME out of copy this table cannot
    /// own — a `ShotStep`'s title/hint, a server-driven trending tagline, an AI
    /// direction line, a QC retake reason, a session requirement sentence, a
    /// dismissed room tip's confirmation, or (for `.focusRungAdvanced`) two
    /// already-rendered lines from other moments. `line(for:ctx:)` returns nil
    /// for these and the call site keeps supplying its own string.
    ///
    /// This is the same list `scripts/coach-voice-manifest/generate.swift`
    /// excludes from pre-bake, and that tool fails loudly if the two disagree —
    /// so the set cannot drift into "excluded here, expected there".
    static let openSet: Set<CoachMoment> = [
        .shotStepHint, .shotStepAnnounce, .shotCaptured, .trendingSetIntro,
        .aiDirectionReady, .retakeConfirm, .retakeAnnounce,
        .sessionGuideNoteMet, .sessionGuideNoteOutstanding, .sessionOutstandingSentence,
        .leavingWithoutTitleSession, .roomTipDismissed, .focusRungAdvanced,
    ]

    /// The canonical line for `moment`, or nil where this table does not own
    /// the words: an `openSet` moment, or an interpolating moment whose
    /// `ctx` is missing the value its sentence is built around.
    ///
    /// Every non-`openSet` moment has text for every context `contexts(for:)`
    /// declares — `CoachCanonicalCopyTests` derives that check from
    /// `CoachMoment.allCases` so a new moment cannot be added without one.
    static func line(for moment: CoachMoment,
                     ctx: CoachPhraseContext = CoachPhraseContext()) -> String? {
        switch moment {

        // MARK: - Lighting (LightingCoach, ShotCoach.swift)

        case .lightingBacklit:
            return "Light’s behind them — turn them to face the window"
        case .lightingTooDark:
            // `namesAPerson` is `ctx.faceLuma != nil` at the call site: expose
            // for the skin when there is skin, for the whole frame otherwise.
            return ctx.namesAPerson ? "Their face is too dark — turn them toward the light"
                                    : "Too dark — move toward the light"
        case .lightingBlownOut:
            return ctx.namesAPerson ? "Their face is blown out — turn away from the bright light"
                                    : "Blown out — turn away from the bright light"

        // MARK: - Composition (CompositionCoach, ShotCoach.swift)

        case .compositionTooFar:
            return "Move in closer — fill the frame"
        case .compositionTooClose:
            return "Too tight — step back a touch"
        case .compositionFaceRequired:
            return "Frame their face for this shot"
        case .compositionOffFrame:
            return "They’re outside the feed crop — center them"
        case .compositionNoHeadroom:
            return "Leave a little headroom — lower the camera"
        case .compositionTooLow:
            return "Raise the camera — they’re too low"
        case .compositionRecenter:
            return "Center them"

        // MARK: - Sharpness (SharpnessCoach, ShotCoach.swift)

        case .sharpnessHoldSteady:
            return "Hold steady — shot looks soft"
        case .sharpnessTapToFocus:
            return "Tap to focus — a touch soft"

        // MARK: - Background (BackgroundCoach, ShotCoach.swift)

        case .backgroundBusy:
            return "Busy background — find a cleaner backdrop"

        // MARK: - Pose (PoseCoach, ShotCoach.swift)

        case .poseClipped:
            return "They’re getting clipped — pull back"

        // MARK: - Level (LevelCoach, ShotCoach.swift)

        case .levelTilted:
            // A POSITION, never a "move this way" instruction — see
            // `CoachPhraseContext.direction`. No side, no sentence.
            guard let direction = ctx.direction else { return nil }
            return "Camera’s tilted \(direction) — straighten it"
        case .levelAlmostLevel:
            return "Almost level — straighten up"

        // MARK: - Color (ColorCoach, ShotCoach.swift)

        case .colorMixed:
            return "Mixed light — turn off the overheads"
        case .colorGreenish:
            return "Greenish light — switch to one clean source"
        case .colorWarm:
            return "Warm light — daylight reads truer"

        // MARK: - A fundamental passing
        //
        // The SPOKEN form. Its sibling `canonicalGoodPhrase` is the dimensions
        // drawer's row label — displayed, never spoken, terse and unpunctuated
        // because it sits in a column of statuses. Joining the label onto the
        // next instruction is what produced "Sharp Center them" in one breath.

        case .goodLighting:   return CoachCategory.lighting.canonicalGoodSentence
        case .goodColor:      return CoachCategory.color.canonicalGoodSentence
        case .goodLevel:      return CoachCategory.level.canonicalGoodSentence
        case .goodFraming:    return CoachCategory.composition.canonicalGoodSentence
        case .goodSharpness:  return CoachCategory.sharpness.canonicalGoodSentence
        case .goodBackground: return CoachCategory.background.canonicalGoodSentence
        case .goodPose:       return CoachCategory.pose.canonicalGoodSentence

        // MARK: - The lane's own lines (CameraCoachLane.swift)

        case .laneHoldShooting:
            return "Hold it — shooting"
        case .laneSetComplete:
            return "That’s the full set — beautiful work"
        case .laneCalibrationDrift:
            return "Light’s changed — re-scan the card"

        // MARK: - A fundamental just cleared (CoachEngine.swift)

        case .dimensionCleared:
            // `ctx.subjectNoun` is the cleared `CoachCategory.spokenName`.
            guard let cleared = ctx.subjectNoun else { return nil }
            return "\(cleared) — got it"

        // MARK: - Post-capture QC (PhotoQC.swift)

        case .qcEyesClosed:
            return "Their eyes were closed"
        case .qcSoft:
            return "It came out soft"
        case .qcTooDark:
            // `ctx.subjectNoun` is "It" or "Their face" — whole-image luma is
            // the room; when there's a face in the shot, the face IS the
            // exposure, and the sentence has to say which it judged.
            guard let subject = ctx.subjectNoun else { return nil }
            return "\(subject) came out too dark"
        case .qcBlownOut:
            guard let subject = ctx.subjectNoun else { return nil }
            return "\(subject) came out blown out"

        // MARK: - Before/after light match (BeforeShotMeasure.swift)

        case .lightMatched:
            // `ctx.subjectNoun` is "before" (the booking's own before shot) or
            // "reference" (a look being matched).
            guard let noun = ctx.subjectNoun else { return nil }
            return "Light matches the \(noun)"
        case .lightBrighterThan:
            guard let noun = ctx.subjectNoun else { return nil }
            return "Brighter than the \(noun) — dim a touch"
        case .lightDarkerThan:
            guard let noun = ctx.subjectNoun else { return nil }
            return "Darker than the \(noun) — add light"
        case .lightWarmerThan:
            guard let noun = ctx.subjectNoun else { return nil }
            return "Warmer than the \(noun) — cool the light"
        case .lightCoolerThan:
            guard let noun = ctx.subjectNoun else { return nil }
            return "Cooler than the \(noun) — warm the light"

        // MARK: - Before/after PAIR (BeforePair.swift)

        case .pairedWithBefore:
            // Names the two things that matched rather than saying "matched":
            // a pro who cannot see WHAT the coach checked has been handed a
            // compliment instead of a measurement. Only ever about the
            // booking's own before, so there is no noun to interpolate.
            return "Light and framing match the before"

        // MARK: - The camera's spoken announcements (ProCapturePhotosView.swift)

        case .matchingReferenceLook:
            return "Matching your reference look."

        // MARK: - Practice framing (ProCameraDestination.swift)

        case .practiceGuideNote:
            return "Practice shots aren’t attached to anyone. Shoot as many as you like — you can attach one to a client or a look later."
        case .leavingWithoutTitlePractice:
            return "Leave the camera?"

        // MARK: - Open set — the call site owns these words, not this table.

        case .shotStepHint, .shotStepAnnounce, .shotCaptured, .trendingSetIntro,
             .aiDirectionReady, .retakeConfirm, .retakeAnnounce,
             .sessionGuideNoteMet, .sessionGuideNoteOutstanding, .sessionOutstandingSentence,
             .leavingWithoutTitleSession, .roomTipDismissed, .focusRungAdvanced:
            return nil
        }
    }

    /// `line(for:ctx:)` for the moments this table OWNS — everything outside
    /// `openSet`, asked with a context that carries whatever its sentence
    /// interpolates.
    ///
    /// The empty string is unreachable rather than a real fallback:
    /// `CoachCanonicalCopyTests` walks `CoachMoment.allCases` and asserts every
    /// non-`openSet` moment renders non-empty text for every context
    /// `contexts(for:)` declares, and every call site here passes one of those.
    /// It exists only because Swift cannot say "this subset of the enum always
    /// has text" without a second enum — and a second enum is exactly what
    /// would stop the completeness check deriving from the SSOT.
    static func ownedLine(for moment: CoachMoment,
                          ctx: CoachPhraseContext = CoachPhraseContext()) -> String {
        line(for: moment, ctx: ctx) ?? ""
    }

    /// Every context `moment`'s canonical text actually varies over — one
    /// entry for a moment whose line is fixed, one per real value otherwise.
    ///
    /// The values are the ones the shipping app supplies, not invented here:
    /// `CoachCategory.spokenName` for a cleared dimension, `PhotoQC`'s
    /// "It"/"Their face", `BeforeShotMeasure`'s "before"/"reference",
    /// `LevelCoach`'s "left"/"right", and `LightingCoach`'s `faceLuma != nil`.
    ///
    /// It lives here rather than in the tooling so the table stays
    /// self-describing: `scripts/coach-voice-manifest` cross-products this to
    /// find every recordable line, and `CoachCanonicalCopyTests` proves a
    /// moment that declares no domain really does render the same words for
    /// any context — so an interpolation added without a domain fails loudly
    /// instead of silently costing the default voice its audio.
    static func contexts(for moment: CoachMoment) -> [CoachPhraseContext] {
        switch moment {
        case .lightingTooDark, .lightingBlownOut:
            return [CoachPhraseContext(namesAPerson: false),
                    CoachPhraseContext(namesAPerson: true)]
        case .levelTilted:
            return ["left", "right"].map { CoachPhraseContext(direction: $0) }
        case .dimensionCleared:
            return CoachCategory.allCases.map { CoachPhraseContext(subjectNoun: $0.spokenName) }
        case .qcTooDark, .qcBlownOut:
            return ["It", "Their face"].map { CoachPhraseContext(subjectNoun: $0) }
        case .lightMatched, .lightBrighterThan, .lightDarkerThan,
             .lightWarmerThan, .lightCoolerThan:
            return ["before", "reference"].map { CoachPhraseContext(subjectNoun: $0) }
        default:
            return [CoachPhraseContext()]
        }
    }
}
