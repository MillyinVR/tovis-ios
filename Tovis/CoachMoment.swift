// The coaching VOCABULARY the decision layer tags its signals with — moved out
// of `CoachVoice.swift` (2026-08-23) so the two layers can be compiled apart.
//
// `CoachMoment` is a stable tag that `ShotCoach`/`CoachAggregate`/
// `CoachTipArbiter` attach to what they decide; a `CoachVoice` pack later
// RENDERS a moment into words. The decision half depends only on Foundation.
// The rendering half needs `CoachPersonality`, which lives in a SwiftUI file —
// so while both halves shared one file, anything that compiled the coaches
// (notably `scripts/coach-tuning-bench`, which builds the live perception
// sources on the Mac with no simulator) had to drag SwiftUI in behind them.
//
// Splitting the file changes no behaviour: every declaration here is moved
// byte-for-byte, and the §0 guardrail is untouched — nothing in this file
// reads a `CoachVoice`, and nothing here decides anything. It is the shared
// noun list the two layers meet over.
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

    /// Room memory (camera plan P4.1): the pro has just told the coach that a
    /// room condition — the salon's overheads, its backdrop — is not theirs
    /// to change, and the coach has retired that tip at this location. The one
    /// sentence the coach says back. `ctx.detail` carries the ALREADY-chosen
    /// canonical sentence for the specific condition
    /// (`CoachRoomMemory.confirmation(for:)`), so a pack supplies only the
    /// bridge around it — same wrapping contract as `.sessionGuideNoteMet`.
    case roomTipDismissed
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
    /// A side, "left" or "right" — `LevelCoach`'s tilt direction, and
    /// `CompositionCoach`'s read of which side of centre the subject is
    /// sitting on. Always a POSITION, never a "move this way" instruction:
    /// the move direction is the sign convention the level coach still has
    /// flagged unverified, and nothing here should become a second one.
    var direction: String?
    /// The cleared dimension's spoken name, for `.dimensionCleared`; the shot
    /// title, the light-match noun ("before"/"reference"), the QC subject
    /// ("It"/"Their face") for the Phase 4 moments that name a thing.
    var subjectNoun: String?
    /// Reserved for a future moment that needs a count.
    var count: Int?
    /// Whether this line is about the PERSON in front of the lens, rather than
    /// the room, the camera, or a flat-lay of the work. It exists because two
    /// moments carry BOTH kinds of line under one tag — `LightingCoach`'s
    /// `onFace` picks between "their face is too dark" and "too dark" — so a
    /// render that wants to name the client can tell them apart without
    /// re-deriving it from the message string.
    var namesAPerson: Bool = false
    /// A second interpolated string for Phase 4 moments that wrap a piece of
    /// existing text rather than just naming a thing — a step's hint, a
    /// pack's tagline, an AI direction line, a QC retake reason, a session
    /// requirement sentence. Deliberately the CANONICAL text, never another
    /// moment's already-flourished render: stacking two packs' flourishes
    /// into one utterance is how "It came out too dark, bestie — one more!
    /// — retake while they're right there, bestie?" happens. One flourish
    /// per utterance, from whichever moment is doing the wrapping.
    var detail: String?

    init(direction: String? = nil, subjectNoun: String? = nil, count: Int? = nil,
         detail: String? = nil, namesAPerson: Bool = false) {
        self.direction = direction
        self.subjectNoun = subjectNoun
        self.count = count
        self.detail = detail
        self.namesAPerson = namesAPerson
    }
}
