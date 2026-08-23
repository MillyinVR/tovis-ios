// The tone-only rendering seam for the AI-photographer coach — see
// docs/design/camera-personality-packs.md.
//
// The trigger/decision pipeline (`ShotCoach.evaluate` → `CoachAggregate` →
// `CoachTipArbiter`) keeps deciding WHAT'S wrong and WHEN to act, unchanged,
// and keeps returning Calm Mentor text as its canonical `message`/`why` — the
// pinned `CoachReadinessTests`/`CoachTipArbiterTests` assert on exactly that
// text. A `CoachMoment` tag rides alongside the canonical string; the pro's
// chosen `CoachVoice` renders a line for that moment at the three places copy
// reaches the user (`CoachEngine.speak`, `CameraCoachLane.message`,
// `DimensionsDrawer`). No override for a moment → the renderer falls back to
// the canonical string, never a blank or a crash.
//
// The moments themselves — `CoachMoment`, `CoachPhraseContext` and the
// `CoachCategory` good-phrase pair — live in `CoachMoment.swift`. They are
// vocabulary the DECISION layer tags signals with, and it must be compilable
// without the SwiftUI dependency `CoachPersonality` brings in below.
import Foundation

/// How much a personality talks. Intrinsic to the pack, not a separate
/// user-facing control (design doc §2.3). Governs whether `why` rides along
/// with the fix — never `CoachTuning` timing.
enum CoachChattiness: Sendable {
    case minimal, standard, expressive
}

/// A user-selectable coaching voice. Implementations render TONE ONLY: they
/// see a `CoachMoment` and a small interpolation payload, never a
/// `FrameContext` or a `CoachTuning` threshold — there is nothing here a
/// voice could use to change what's decided, only what's said.
protocol CoachVoice: Sendable {
    var id: CoachPersonality { get }
    var displayName: String { get }
    var chattiness: CoachChattiness { get }
    /// The line for this moment, or nil to defer to the canonical fallback
    /// (an intentional gap, not an error).
    func phrase(for moment: CoachMoment, ctx: CoachPhraseContext) -> String?
    /// Whether the corrective's WHY rides along when this moment is spoken /
    /// shown. Defaults to the pack's chattiness — minimal packs skip it.
    func includesWhy(for moment: CoachMoment) -> Bool

    // MARK: - Delivery (how it SOUNDS, never what fires)
    //
    // `CoachEngine.speak` multiplies these onto the one system voice
    // `CoachSpeechVoice` resolves (the best Enhanced/Premium voice actually
    // installed) — personalities never pick a different underlying voice,
    // only how it's paced. Same guardrail as the words themselves: nothing
    // here can be seen from `ShotCoach`/`CoachAggregate`/`CoachTuning`, so a
    // pack has no way to reach the decision layer through delivery either.

    /// Multiplies `AVSpeechUtteranceDefaultSpeechRate`. 1.0 = system default;
    /// under 1 is slower/warmer, over 1 is brisker.
    var speechRateMultiplier: Float { get }
    /// `AVSpeechUtterance.pitchMultiplier` (0.5–2.0). 1.0 = unchanged; under 1
    /// reads lower/composed, over 1 reads brighter/lifted.
    var speechPitch: Float { get }
    /// A small breath before the utterance starts — composed packs pause
    /// longer, eager ones jump right in. Real speech rarely starts on a
    /// dead cut, which is a good part of why raw default-rate TTS reads as
    /// robotic even with a natural-sounding voice underneath it.
    var preUtteranceDelay: TimeInterval { get }
}

extension CoachVoice {
    func includesWhy(for moment: CoachMoment) -> Bool { chattiness != .minimal }
}

/// The only place a moment turns into on-screen/spoken text — called from
/// the three render sites the design doc identifies. Nothing upstream of
/// those call sites (evaluate → aggregate → arbiter) ever sees a `CoachVoice`.
enum CoachVoiceRenderer {
    static func render(
        _ moment: CoachMoment?, fallback: String?,
        ctx: CoachPhraseContext = CoachPhraseContext(), voice: CoachVoice
    ) -> String? {
        guard let moment else { return fallback }
        return voice.phrase(for: moment, ctx: ctx) ?? fallback
    }
}

/// Today's voice, ported byte-identical: it never overrides the canonical
/// text, so every render call falls straight through to `fallback` — which
/// IS today's Calm Mentor string, unchanged by this feature. This is what
/// keeps the pinned tests and every existing on-screen/spoken line exactly
/// as they were before personalities existed.
///
/// Delivery is the one thing that's deliberately NOT byte-identical to
/// before: raw `AVSpeechUtteranceDefaultSpeechRate` at neutral pitch with no
/// lead-in is what made the coach sound like a machine even saying warm
/// words. A touch slower, a touch lower, a short breath first — measured and
/// warm, not flat.
struct CalmMentorVoice: CoachVoice {
    let id: CoachPersonality = .calmMentor
    let displayName = "Calm Mentor"
    let chattiness: CoachChattiness = .standard
    let speechRateMultiplier: Float = 0.94
    let speechPitch: Float = 0.96
    let preUtteranceDelay: TimeInterval = 0.15
    func phrase(for moment: CoachMoment, ctx: CoachPhraseContext) -> String? { nil }
}
