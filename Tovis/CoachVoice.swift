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
}

extension CoachCategory {
    /// The moment a fundamental's passing state renders through — the
    /// personality-flavored counterpart to `DimensionsDrawer.goodPhrase`.
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
    /// A second interpolated string for Phase 4 moments that wrap ANOTHER
    /// already-rendered line rather than just naming a thing — a step's hint,
    /// a pack's tagline, an AI direction line, a QC retake reason already run
    /// through its own moment. Keeps the wrapping moment's pack copy from
    /// re-authoring content that another render call already owns.
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
struct CalmMentorVoice: CoachVoice {
    let id: CoachPersonality = .calmMentor
    let displayName = "Calm Mentor"
    let chattiness: CoachChattiness = .standard
    func phrase(for moment: CoachMoment, ctx: CoachPhraseContext) -> String? { nil }
}
