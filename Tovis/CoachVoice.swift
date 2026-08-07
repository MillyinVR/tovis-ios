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
import Foundation

/// A stable tag alongside a canonical coaching signal — one case per literal
/// in the launch scope (docs/design/camera-personality-packs.md §1.2 A–D).
/// `PoseRule.tip` (server-driven trending-pack copy) intentionally has no
/// case here — it stays pack-neutral at every personality.
enum CoachMoment: Hashable, CaseIterable, Sendable {
    case lightingBacklit, lightingTooDark, lightingBlownOut

    case compositionTooFar, compositionTooClose, compositionFaceRequired
    case compositionOffFrame, compositionNoHeadroom, compositionTooLow
    case compositionRecenter

    case sharpnessHoldSteady, sharpnessTapToFocus

    case backgroundBusy

    case poseClipped

    case levelTilted, levelAlmostLevel

    case colorMixed, colorGreenish, colorWarm

    case goodLighting, goodColor, goodLevel, goodFraming
    case goodSharpness, goodBackground, goodPose

    case laneHoldShooting, laneSetComplete, laneCalibrationDrift

    case dimensionCleared

    // MARK: - Phase 4 (docs/design/camera-personality-packs.md §4, sites E–I)
    // Deferred-scope moments: post-capture QC, before/after light matching,
    // the directed-shoot step hint, the camera's spoken announcements/dialogs,
    // and the session-vs-practice framing copy. Same architecture as A–D —
    // these just reach three more decision layers downstream of the live coach.

    /// E — `PhotoQC`'s post-capture retake verdict.
    case qcEyesClosed, qcSoft, qcTooDark, qcBlownOut

    /// F — `BeforeShotMeasure.LightMatch`'s before/after light verdict.
    case lightMatched, lightBrighterThan, lightDarkerThan, lightWarmerThan, lightCoolerThan

    /// G — `ShotGuide.ShotStep.hint`, wherever it's shown as the standing
    /// how-to (the guide sheet's current-step row, the lane's resting/transient
    /// step text). `title` stays canonical everywhere — it's also the step's
    /// `Identifiable` id.
    case shotStepHint

    /// H — `ProCapturePhotosView`'s `coach?.announce(...)` call sites and the
    /// photographer-check retake dialog.
    case shotStepAnnounce, shotCaptured, trendingSetIntro, matchingReferenceLook, aiDirectionReady
    case retakeConfirm, retakeAnnounce

    /// I — `ProCameraDestination`'s session/practice framing copy.
    case sessionGuideNoteMet, sessionGuideNoteOutstanding, practiceGuideNote
    case sessionOutstandingSentence, leavingWithoutTitleSession, leavingWithoutTitlePractice

    /// Sequential focus coaching (docs/design, 2026-08-06): the coach just
    /// advanced off a rung that read stable-good, onto a next broken one —
    /// compliment the finished rung, then redirect. `ctx.subjectNoun` carries
    /// the ALREADY-rendered compliment (this voice's own `goodMoment` line);
    /// `ctx.detail` carries the ALREADY-rendered next correction (this
    /// voice's own line for whatever moment comes next). Both are complete
    /// sentences in this voice already — a pack's template for this moment
    /// only ever supplies the bridge between them, never re-flourishes either
    /// half (see the retake-flow note in `CoachPhraseContext.detail`).
    case focusRungAdvanced
}

extension CoachCategory {
    /// The moment a fundamental's passing state renders through — the
    /// personality-flavored counterpart to `canonicalGoodPhrase`.
    var goodMoment: CoachMoment {
        switch self {
        case .lighting: return .goodLighting
        case .color: return .goodColor
        case .level: return .goodLevel
        case .composition: return .goodFraming
        case .sharpness: return .goodSharpness
        case .background: return .goodBackground
        case .pose: return .goodPose
        }
    }

    /// The canonical (Calm Mentor) text for this fundamental passing —
    /// `goodMoment`'s plain-English fallback. Shared between the dimensions
    /// drawer's always-on-screen row and the focus ladder's compliment-on-
    /// advance line, so there's exactly one "it's good" sentence per
    /// fundamental rather than two that can drift apart.
    var canonicalGoodPhrase: String {
        switch self {
        case .lighting: return "Good light"
        case .color: return "Colour is true"
        case .level: return "Level"
        case .composition: return "Framed"
        case .sharpness: return "Sharp"
        case .background: return "Background is clean"
        case .pose: return "Pose reads"
        }
    }
}

/// Interpolation payload for the handful of moments whose canonical text has
/// a `\(...)` in it — covers every one seen in the launch scope without a
/// pack needing to know `FrameContext` internals.
nonisolated struct CoachPhraseContext: Sendable, Equatable {
    /// `LevelCoach`'s tilt direction ("left"/"right").
    var direction: String?
    /// The cleared dimension's spoken name, for `.dimensionCleared`; the shot
    /// title, the light-match noun ("before"/"reference"), the QC subject
    /// ("It"/"Their face") for the Phase 4 moments that name a thing.
    var subjectNoun: String?
    /// Reserved for a future moment that needs a count.
    var count: Int?
    /// A second interpolated string for Phase 4 moments that wrap a piece of
    /// existing text rather than just naming a thing — a step's hint, a
    /// pack's tagline, an AI direction line, a QC retake reason, a session
    /// requirement sentence. Deliberately the CANONICAL text, never another
    /// moment's already-flourished render: stacking two packs' flourishes
    /// into one utterance is how "It came out too dark, bestie — one more!
    /// — retake while they're right there, bestie?" happens. One flourish
    /// per utterance, from whichever moment is doing the wrapping.
    var detail: String?

    init(direction: String? = nil, subjectNoun: String? = nil, count: Int? = nil, detail: String? = nil) {
        self.direction = direction
        self.subjectNoun = subjectNoun
        self.count = count
        self.detail = detail
    }
}

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
