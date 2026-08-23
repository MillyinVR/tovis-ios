// The on-device "AI photographer" coach model. Each `ShotCoach` judges ONE aspect
// of the live frame (lighting, composition, …) and returns a 0–1 score + a plain-
// language fix. The engine aggregates them into a readiness value + the single
// most important tip. Pure + Sendable so they run on the camera's frame queue.
//
// Coaches: Lighting, Composition, Sharpness, Background, Pose. The `FrameContext`
// carries pre-computed signals so coaches don't each re-scan, and every perception
// threshold lives in `CoachTuning` (one file to adjust during device tuning).
import CoreGraphics
import Foundation   // TimeInterval — the tip arbiter's dwell clock
import TovisKit     // PublishCrop — the crop the coach judges inside

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

/// How serious a broken fundamental is — the ONE thing that can move a
/// correction ahead of its place in the focus ladder's fixed order.
///
/// The line between them is not "how bad does it score": it is whether the
/// CAPTURE survives. A `.failure` frame is one no edit afterwards recovers —
/// clipped highlights have no data left, shadows lifted off an underexposed
/// face come back as noise, motion blur is gone for good. A `.correction` is a
/// choice about the room, the framing or the pose that the very next frame can
/// simply make differently, at no cost to the file.
///
/// Kept as its own axis rather than derived from `score` on purpose: the scores
/// are perception calibration the salon pass is expected to move, and a retune
/// must not silently redecide which line the pro is shown.
enum CoachSeverity: Sendable {
    /// Something to fix, taken in the ladder's own big-adjustment-first order.
    case correction
    /// A hard failure — this frame is being thrown away whatever else is right.
    case failure
}

/// One coach's read on the current frame. `score` is 0 (bad) … 1 (great);
/// `message` is the corrective tip, present only when there's something to fix.
struct CoachSignal: Sendable {
    let score: Double
    let message: String?
    /// Whether this is an unrecoverable failure or an ordinary correction.
    /// Only meaningful when `message` is non-nil, and only ever read by
    /// `CoachTipArbiter` — never by readiness, which stays a pure weighted mean
    /// of the scores.
    let severity: CoachSeverity
    /// WHY the tip is worth acting on, in a photographer's terms. The message
    /// is an imperative ("Move in closer"); this is the sentence a photographer
    /// would add after it, surfaced in the dimensions drawer. Nil where the
    /// message speaks for itself — or where there is no message at all.
    let why: String?
    /// The stable tag a `CoachVoice` renders this signal's line from. Nil
    /// where `message` is nil (nothing to say) or where the message is
    /// intentionally pack-neutral (`PoseRule.tip`). `message`/`why` stay the
    /// canonical Calm Mentor text either way — this only ever ADDS a render
    /// hook, never changes what's decided.
    let moment: CoachMoment?
    /// Interpolation values for the rare moment whose canonical text has a
    /// `\(...)` in it (see `CoachPhraseContext`).
    let phraseCtx: CoachPhraseContext?

    init(score: Double, message: String?, why: String? = nil,
         moment: CoachMoment? = nil, phraseCtx: CoachPhraseContext? = nil,
         severity: CoachSeverity = .correction) {
        self.score = score
        self.message = message
        self.why = why
        self.moment = moment
        self.phraseCtx = phraseCtx
        self.severity = severity
    }
}

/// A prioritized tip surfaced to the pro (chip / voice).
struct CoachNudge: Sendable, Equatable {
    let category: CoachCategory
    let message: String
    let moment: CoachMoment?
    let phraseCtx: CoachPhraseContext?

    init(category: CoachCategory, message: String,
         moment: CoachMoment? = nil, phraseCtx: CoachPhraseContext? = nil) {
        self.category = category
        self.message = message
        self.moment = moment
        self.phraseCtx = phraseCtx
    }
}

/// One fundamental's live status, for the at-a-glance checklist HUD.
struct CoachStatus: Sendable, Equatable, Identifiable {
    let category: CoachCategory
    let score: Double
    /// The corrective tip, if this fundamental needs attention right now.
    let message: String?
    /// Why that tip matters — shown under it in the dimensions drawer, which is
    /// the one surface the pro opened on purpose to ask "why won't it go green?"
    let why: String?
    /// The moment this status's `message` renders through, when there's a
    /// message. Nil (not `category.goodMoment`) when the fundamental is
    /// passing — the drawer derives the passing moment from `category`
    /// itself, since there's no signal to tag there.
    let moment: CoachMoment?
    let phraseCtx: CoachPhraseContext?
    var id: String { category.rawValue }

    init(category: CoachCategory, score: Double, message: String?, why: String? = nil,
         moment: CoachMoment? = nil, phraseCtx: CoachPhraseContext? = nil) {
        self.category = category
        self.score = score
        self.message = message
        self.why = why
        self.moment = moment
        self.phraseCtx = phraseCtx
    }
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
    /// Whole-frame luma of this frame.
    let frameLuma: Double
    /// Warmth of this frame's LIGHT — measured on the segmented background when
    /// there is one (see `ColorSignal`), so a client's warm top doesn't read as
    /// a warm room. Also what the calibration-drift watcher compares.
    let frameWarmth: Double?
    /// Luma of the segmented background. The before/after light matcher prefers
    /// this pair (`frameBackgroundLuma` + `frameWarmth`) over the whole frame:
    /// a dark-to-blonde colour service legitimately changes whole-frame luma —
    /// that IS the work — and the matcher used to call it a light mismatch.
    let frameBackgroundLuma: Double?
    /// The rung the focus ladder just fully cleared, with nothing left broken
    /// to move to. Mutually exclusive with `advanced`.
    let cleared: CoachCategory?
    /// The rung the focus ladder just advanced OFF of, onto a next broken one
    /// (`nudge` is that next rung's tip) — the "compliment, then redirect"
    /// moment. Mutually exclusive with `cleared`.
    let advanced: CoachCategory?
    /// Raw perception values for the DEBUG tuning console. Nil unless the
    /// console is open (`CoachDebug.captureSignals`) — zero cost otherwise.
    let debug: [DebugSignal]?
}

/// One raw perception value surfaced in the DEBUG tuning console.
struct DebugSignal: Sendable, Identifiable, Equatable {
    let name: String
    let value: Double
    var id: String { name }
}

/// DEBUG-only switch: when the tuning console is open, the analyzer attaches
/// raw signal values to each result so thresholds can be set against what the
/// camera actually measures (instead of guessed).
enum CoachDebug {
    nonisolated(unsafe) static var captureSignals = false
}

/// Key body joints the pose engine reasons about (subset of Vision's set).
nonisolated enum PoseJoint: Sendable, Hashable {
    case leftShoulder, rightShoulder, leftWrist, rightWrist, leftHip, rightHip, neck, nose
}

/// Body-pose read for the current frame, present when a human body is
/// confidently detected. Coordinates already resolved to the upright frame
/// (top-left normalized). (Camera tilt is judged by `LevelCoach` from the
/// device's gravity vector — far more reliable than inferring it from the
/// subject's shoulders.)
nonisolated struct PoseSignal: Sendable {
    /// A confidently-detected joint sits hard against a frame edge → subject is
    /// being clipped.
    let edgeClipped: Bool
    /// Confident joints only (low-confidence points are absent, not zeroed).
    let joints: [PoseJoint: CGPoint]
}

/// One measurable pose constraint from a trending shot pack. The VOCABULARY is
/// fixed app-side (these kinds map to evaluators in `PoseCoach`); the server
/// composes current trends from it, and unknown kinds are dropped at parse
/// time so the server can ship new vocabulary ahead of old app builds.
nonisolated struct PoseRule: Sendable, Equatable {
    enum Kind: String, Sendable {
        /// A wrist within `maxFaceHeights` of the face center.
        case handNearFace
        /// Both wrists confidently in frame.
        case bothHandsVisible
        /// Shoulder line at least `minDegrees` off level (dropped-shoulder look).
        case shouldersTilted
        /// Shoulder line within `maxDegrees` of level.
        case shouldersLevel
        /// Face center within `maxFaceWidths` of a shoulder (over-the-shoulder).
        case faceNearShoulder
    }

    let kind: Kind
    let params: [String: Double]
    /// The directive shown/spoken while the rule is unmet.
    let tip: String
}

/// Color-of-light read for the frame. Mixed light (warm bulb + cool window) is the
/// #1 real-world beauty-photo killer; a strong green (fluorescent) or warm/yellow
/// (incandescent) cast misrepresents skin tone and the work. Daylight (~neutral) is
/// the target. All values from the frame's average color; no reference card.
nonisolated struct ColorSignal: Sendable {
    /// Spread of warm↔cool across the frame, 0…~1 — high = mixed light sources.
    let mixed: Double
    /// Global green tint, signed (+green / −magenta). Strong + = fluorescent.
    let greenTint: Double
    /// Global warmth, signed (+warm/yellow / −cool/blue). Strong + = warm bulbs.
    let warmth: Double
    /// True when all three were measured on the segmented BACKGROUND only — the
    /// colour OF THE LIGHT rather than of the client's top. False when no person
    /// was segmented, in which case the whole frame IS the background (a flat-lay
    /// or a detail shot) and standing in for it is correct, not a fallback.
    let backgroundScoped: Bool

    init(mixed: Double, greenTint: Double, warmth: Double, backgroundScoped: Bool = false) {
        self.mixed = mixed
        self.greenTint = greenTint
        self.warmth = warmth
        self.backgroundScoped = backgroundScoped
    }
}

/// Pre-computed, orientation-corrected signals for the current frame. Coordinates
/// are normalized with origin TOP-LEFT (UIKit-style) so composition math is simple.
struct FrameContext: Sendable {
    /// Average luma of the whole frame, 0…1.
    let avgLuma: Double
    /// Largest detected face, normalized (top-left origin). Nil if none.
    let faceBounds: CGRect?
    /// Average luma inside the face region, if a face was found. This — not
    /// `avgLuma` — is what "is this exposed correctly" is judged on when there
    /// is a face: a photographer's first act is to expose for the skin.
    let faceLuma: Double?
    /// Average luma of the segmented BACKGROUND (the subject excluded). Nil
    /// when no person was segmented or there was too little background to
    /// measure. The backlit test compares the face against THIS rather than
    /// against the whole frame, which contains the face — a face-vs-frame ratio
    /// trips on deeper complexions in evenly-lit rooms with no backlight at all.
    let backgroundLuma: Double?
    /// Focus quality 0…1 (measured on the subject region when a face is present,
    /// else the whole frame). Low = soft / motion-blurred.
    let sharpness: Double
    /// Busy-ness of the area behind the subject, 0 (clean) … 1 (cluttered). Nil
    /// when no person is segmented, so non-portrait shots aren't nagged.
    let backgroundClutter: Double?
    /// Fraction of the frame the subject (segmented person) fills, 0…1. Nil when no
    /// person is segmented (flat-lay / detail shots aren't nagged to "get closer").
    let subjectFill: Double?
    /// The publish crop the pro is composing to (`PublishCrop.feedRect`), as a
    /// normalized top-left rect of the capture frame — set while the crop guide
    /// is on. Composition is judged INSIDE it, because that is the picture that
    /// ships. Nil = judge the whole capture frame, as before.
    let cropGuide: CGRect?
    /// Subject fill measured inside `cropGuide` rather than over the whole
    /// frame. Nil when there is no crop guide or no person is segmented.
    let cropSubjectFill: Double?
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

    /// Written out rather than synthesized so the signals added for the
    /// background- and crop-scoped judgements can default to "not measured" —
    /// which is exactly what they are on a frame where segmentation found no
    /// person or the pro has the crop guide off.
    init(
        avgLuma: Double,
        faceBounds: CGRect?,
        faceLuma: Double?,
        backgroundLuma: Double? = nil,
        sharpness: Double,
        backgroundClutter: Double?,
        subjectFill: Double?,
        cropGuide: CGRect? = nil,
        cropSubjectFill: Double? = nil,
        pose: PoseSignal?,
        deviceTilt: Double?,
        color: ColorSignal?,
        expectations: ShotExpectations?
    ) {
        self.avgLuma = avgLuma
        self.faceBounds = faceBounds
        self.faceLuma = faceLuma
        self.backgroundLuma = backgroundLuma
        self.sharpness = sharpness
        self.backgroundClutter = backgroundClutter
        self.subjectFill = subjectFill
        self.cropGuide = cropGuide
        self.cropSubjectFill = cropSubjectFill
        self.pose = pose
        self.deviceTilt = deviceTilt
        self.color = color
        self.expectations = expectations
    }
}

protocol ShotCoach: Sendable {
    var category: CoachCategory { get }
    func evaluate(_ ctx: FrameContext) -> CoachSignal
}

// MARK: - Aggregation

/// Turns the per-coach signals into the readiness value + the one tip to show.
/// Lives here (pure, CoreGraphics-only) rather than inline in the analyzer's
/// frame callback so the scoring arithmetic can be tuned and TESTED without a
/// camera — the perception thresholds need a device, the arithmetic does not.
enum CoachAggregate {
    struct Verdict: Sendable {
        let readiness: Double
        let nudge: CoachNudge?
        let statuses: [CoachStatus]
        /// The rung the ladder was locked on and has just fully cleared, with
        /// NOTHING else broken to move to — the moment the coach can be heard
        /// being SATISFIED rather than only dissatisfied. Nil on every other
        /// frame, and mutually exclusive with `advanced`.
        let cleared: CoachCategory?
        /// The rung the ladder just moved OFF of, because it read stable-good
        /// AND there's a next broken rung to introduce (`nudge` is that next
        /// rung's tip). Nil on every other frame, and mutually exclusive with
        /// `cleared`. This is the "compliment, then redirect" moment —
        /// "lighting's gorgeous — now step back a touch to center them."
        let advanced: CoachCategory?

        init(readiness: Double, nudge: CoachNudge?, statuses: [CoachStatus],
             cleared: CoachCategory? = nil, advanced: CoachCategory? = nil) {
            self.readiness = readiness
            self.nudge = nudge
            self.statuses = statuses
            self.cleared = cleared
            self.advanced = advanced
        }
    }

    /// How badly one coach drags readiness down: its weight × how far short it
    /// scored. Still what the READINESS number (the ring) is built from —
    /// no longer what picks the on-screen tip, which follows the fixed focus
    /// ladder instead (see CoachFocusLadder.swift / `CoachTipArbiter`).
    static func deficit(_ category: CoachCategory, _ signal: CoachSignal) -> Double {
        category.weight * (1 - signal.score)
    }

    /// Rank + arbitrate in one pass. `arbiter` carries the focus-ladder lock
    /// state across frames; `now` is a monotonic clock in seconds.
    static func evaluate(
        _ coaches: [ShotCoach], _ ctx: FrameContext,
        arbiter: inout CoachTipArbiter, now: TimeInterval
    ) -> Verdict {
        let signals = coaches.map { ($0.category, $0.evaluate(ctx)) }
        // Readiness is the importance-weighted mean — light + focus count for more
        // than a clean backdrop, per the beauty-photography priority order.
        // Unchanged by the focus ladder: this is a measurement of the WHOLE
        // frame's quality, not of which one thing the coach is currently
        // talking about.
        let totalWeight = signals.reduce(0.0) { $0 + $1.0.weight }
        let readiness = totalWeight == 0 ? 0
            : signals.reduce(0.0) { $0 + $1.1.score * $1.0.weight } / totalWeight
        let outcome = arbiter.select(from: signals, now: now)
        let statuses = signals.map {
            CoachStatus(category: $0.0, score: $0.1.score, message: $0.1.message, why: $0.1.why,
                       moment: $0.1.moment, phraseCtx: $0.1.phraseCtx)
        }
        return Verdict(readiness: readiness, nudge: outcome.nudge, statuses: statuses,
                       cleared: outcome.cleared, advanced: outcome.advanced)
    }

    /// Single-frame evaluation with no memory — the raw ranking, which is what
    /// the offline bench and the scoring tests want. Delegates to the same
    /// arbiter with a fresh state, so there is exactly one selection rule in
    /// the codebase and this can't drift from what the camera does.
    static func evaluate(_ coaches: [ShotCoach], _ ctx: FrameContext) -> Verdict {
        var fresh = CoachTipArbiter()
        return evaluate(coaches, ctx, arbiter: &fresh, now: 0)
    }
}

/// Sequential focus coaching: locks onto the highest-priority BROKEN rung of
/// `FocusRung`'s fixed big-to-small order and shows/speaks only that
/// correction, instead of re-ranking every analyzed frame by weighted
/// deficit. Three rules:
///
///  • **Lock** — when nothing is locked (session start, or just cleared), the
///    ladder locks onto the highest-PRIORITY rung that's currently broken:
///    ladder order, except that a hard failure outranks its rung (below).
///  • **Advance, stability-gated** — the locked rung only lets go once it's
///    read continuously PASSING for `CoachTuning.focusStabilityWindow`. A
///    momentary good reading (sensor noise, not a real fix) doesn't advance
///    it — the SAME flapping problem `CoachSpeechScheduler` guards on the
///    speech side, guarded here at the source instead. Advancing reports
///    which rung just cleared (`advanced`) so the pro hears it complimented
///    before the next correction, or — if nothing else is broken — reports a
///    plain `cleared` with nothing to redirect to.
///  • **Preemption, hysteresis-guarded** — if a rung that OUTRANKS the current
///    lock reads continuously BROKEN for `CoachTuning.focusRegressionWindow`,
///    the lock jumps to it — no compliment, just a normal corrective redirect.
///    Guarded the same way as advancing: a momentary bad reading doesn't jump
///    the lock, or two borderline rungs would ping-pong the coach between them.
///    Two things outrank: a rung EARLIER in the ladder (the original
///    regression — something already passed has broken again), and a hard
///    failure anywhere.
///
/// **A hard failure outranks its rung** (2026-08-23). The ladder's fixed order
/// is a claim about the SIZE of an adjustment, and it is right about that: fix
/// the room before the framing, the framing before the polish. It is not a
/// claim about whether the photo survives. Focus sits last precisely because
/// "hold still" is the finest instruction — but a frame that is actually
/// motion-blurred is being thrown away, and telling that pro to turn off the
/// overheads is advice about a photo that no longer exists.
///
/// So `CoachSeverity.failure` — an unrecoverable capture, not merely a low
/// score — sorts ahead of ladder order, and hard failures keep the ladder's
/// own big-adjustment-first order among themselves. This restores exactly what
/// the pre-ladder weighted-deficit rule got right (`docs/camera-tuning-bench.md`
/// measured mixed light beating everything "except an outright lighting failure
/// or a clearly soft frame") without giving up sequential coaching: every
/// ordinary correction is still taken strictly in rung order, one at a time.
///
/// This is the decision Tori asked changed once, for everyone: nothing here
/// reads `CoachVoice`/`CoachPersonality`, so the ladder order, the severity
/// rule and their timing are identical no matter which pack ends up speaking it.
struct CoachTipArbiter: Sendable {
    struct Outcome: Sendable {
        let nudge: CoachNudge?
        let cleared: CoachCategory?
        let advanced: CoachCategory?
    }

    /// One broken rung this frame: the tip to show for it, and whether it's a
    /// hard failure. Kept together so the severity can never desync from the
    /// nudge it belongs to.
    private struct BrokenRung {
        let nudge: CoachNudge
        let severity: CoachSeverity
    }

    private var lockedRung: FocusRung?
    /// The last-known tip for the locked rung, kept even after it starts
    /// reading good — the ladder is waiting out the stability window before
    /// admitting that, and the pro shouldn't see the line go blank or the
    /// coach fall silent while that's happening.
    private var lockedNudge: CoachNudge?
    /// When the locked rung FIRST started reading continuously good — nil
    /// whenever it's currently reading bad. `now - this >= focusStabilityWindow`
    /// is what actually triggers an advance.
    private var stableGoodSince: TimeInterval?
    /// The current preemption candidate (the highest-priority rung that
    /// currently OUTRANKS the lock — an earlier rung that broke again, or a
    /// hard failure) and when IT first started reading continuously bad. Reset
    /// whenever the candidate identity changes, so a flickering "something
    /// outranks me" never accumulates enough continuous time to jump the lock.
    private var preemption: (rung: FocusRung, badSince: TimeInterval)?

    init() {}

    mutating func select(
        from signals: [(CoachCategory, CoachSignal)], now: TimeInterval
    ) -> Outcome {
        // At most one broken entry per rung per frame: each category
        // contributes exactly one signal, and composition's OWN internal
        // precedence (unchanged by this) picks which one moment — framing or
        // centering — it's reporting this frame, if any.
        var byRung: [FocusRung: BrokenRung] = [:]
        for (category, signal) in signals {
            guard let message = signal.message else { continue }
            let rung = signal.moment?.focusRung ?? category.defaultFocusRung
            byRung[rung] = BrokenRung(
                nudge: CoachNudge(category: category, message: message,
                                  moment: signal.moment, phraseCtx: signal.phraseCtx),
                severity: signal.severity)
        }

        // Priority order for THIS frame: hard failures first, then the ladder's
        // fixed big-adjustment-first order. Rung raw values are unique, so this
        // is a total order and the sort is deterministic.
        func priority(_ rung: FocusRung) -> (Int, Int) {
            (byRung[rung]?.severity == .failure ? 0 : 1, rung.rawValue)
        }
        let broken = FocusRung.allCases
            .filter { byRung[$0] != nil }
            .sorted { priority($0) < priority($1) }

        guard let locked = lockedRung else {
            // Nothing locked: lock onto the highest-priority broken rung, if any.
            guard let first = broken.first else { return Outcome(nudge: nil, cleared: nil, advanced: nil) }
            lock(onto: first, nudge: byRung[first]?.nudge, now: now)
            return Outcome(nudge: byRung[first]?.nudge, cleared: nil, advanced: nil)
        }

        // Preemption check: does anything currently OUTRANK the lock? A lock
        // that is passing this frame has no severity of its own, so it is
        // ranked as an ordinary correction at its rung — which is what lets a
        // hard failure elsewhere take it, and keeps the pre-severity behaviour
        // exactly when no failure is in play.
        let lockedPriority = priority(locked)
        if let candidate = broken.first(where: { priority($0) < lockedPriority }) {
            if preemption?.rung != candidate { preemption = (candidate, now) }
            if now - preemption!.badSince >= CoachTuning.focusRegressionWindow {
                // Trusted — jump to it. Not a completion, so no compliment.
                lock(onto: candidate, nudge: byRung[candidate]?.nudge, now: now)
                return Outcome(nudge: byRung[candidate]?.nudge, cleared: nil, advanced: nil)
            }
            // Not trusted yet; keep working the current lock below.
        } else {
            preemption = nil
        }

        if let current = byRung[locked]?.nudge {
            // Still broken (however it's currently worded) — hold the line.
            lockedNudge = current
            stableGoodSince = nil
            return Outcome(nudge: current, cleared: nil, advanced: nil)
        }

        // Reads good this frame. Only trust it once it's held for the whole
        // stability window.
        if stableGoodSince == nil { stableGoodSince = now }
        guard now - stableGoodSince! >= CoachTuning.focusStabilityWindow else {
            // Not stable yet — keep showing the last known correction rather
            // than going quiet over what might be a flicker.
            return Outcome(nudge: lockedNudge, cleared: nil, advanced: nil)
        }

        // Stable. Advance to the next broken rung, or fully clear. `broken` is
        // priority-sorted, so a hard failure anywhere is taken first; failing
        // that this is the earliest broken rung AFTER the lock, exactly as
        // before. An earlier ordinary rung is still left to the preemption
        // path, which is what makes it serve its hysteresis window.
        if let next = broken.first(where: { $0 > locked || byRung[$0]?.severity == .failure }) {
            lock(onto: next, nudge: byRung[next]?.nudge, now: now)
            return Outcome(nudge: byRung[next]?.nudge, cleared: nil, advanced: locked.category)
        }
        lockedRung = nil
        lockedNudge = nil
        stableGoodSince = nil
        preemption = nil
        return Outcome(nudge: nil, cleared: locked.category, advanced: nil)
    }

    private mutating func lock(onto rung: FocusRung, nudge: CoachNudge?, now: TimeInterval) {
        lockedRung = rung
        lockedNudge = nudge
        stableGoodSince = nil
        preemption = nil
    }
}

private extension FocusRung {
    /// The category a rung's tip is reported under — every rung maps to
    /// exactly one category (composition's split is the only many-to-one
    /// case, and both its rungs still report as `.composition`).
    var category: CoachCategory {
        switch self {
        case .lighting: return .lighting
        case .color: return .color
        case .framing, .centering: return .composition
        case .level: return .level
        case .background: return .background
        case .pose: return .pose
        case .sharpness: return .sharpness
        }
    }
}

// MARK: - Lighting

/// Judges exposure + backlighting — on the SKIN, not on the room.
///
/// A photographer's first act is to expose for the subject's skin. This coach
/// used to make its entire "is this exposed correctly" judgement from
/// `avgLuma`, the whole-frame average, which is dominated by the wall behind
/// the client. The consequence was not evenly distributed: a correctly-lit
/// deep-complexion client against a light salon wall could be badly
/// underexposed while the ring went green and no coach anywhere in the stack
/// said "their face is dark."
///
/// The BANDS are unchanged (they still need the salon pass). What changed is
/// the pixels they are measured over.
struct LightingCoach: ShotCoach {
    let category: CoachCategory = .lighting

    func evaluate(_ ctx: FrameContext) -> CoachSignal {
        // Backlit is a claim about the subject versus what is BEHIND them, so
        // it is measured against the segmented background rather than against a
        // whole-frame average that contains the face and the subject's own
        // clothes. With no mask there is no comparison to make, so the coach
        // makes no claim rather than inventing one.
        //
        // ⚠️ Read this before the salon pass. This relocation makes the rule
        // MORE sensitive at the current ratio, not less: the background is
        // brighter than a frame average that the darker subject was dragging
        // down, so `background × 0.6` is a higher bar than `frame × 0.6`. The
        // relocation is the structurally correct comparison — it is the one
        // that actually means "the light is behind them" — but it does NOT by
        // itself fix the deep-complexion false positive, because no ratio of
        // skin REFLECTANCE to background ILLUMINATION can separate "less light
        // on their face" from "less light coming back off their face".
        // `backlitFaceRatio` is reserved for §3.1 of the plan and setting it is
        // the single most important measurement of the whole device pass;
        // `backlitFaceMaxLuma` is what caps the damage until then.
        // `CoachReadinessTests` pins this direction so it can't surprise anyone.
        if let faceLuma = ctx.faceLuma, let behind = ctx.backgroundLuma,
           faceLuma < behind * CoachTuning.backlitFaceRatio,
           faceLuma < CoachTuning.backlitFaceMaxLuma {
            return CoachSignal(
                score: 0.35,
                message: "Light’s behind them — turn them to face the window",
                why: "The light is behind your client, so the camera exposes for the window and leaves their face in shadow.",
                moment: .lightingBacklit, severity: .failure)
        }

        // Expose for the skin when there is skin to expose for; the whole frame
        // is the fallback for flat-lays and detail shots, where it IS the subject.
        let subject = ctx.faceLuma ?? ctx.avgLuma
        let onFace = ctx.faceLuma != nil

        if subject < CoachTuning.lumaTooDark {
            return CoachSignal(
                score: 0.3,
                message: onFace ? "Their face is too dark — turn them toward the light"
                                : "Too dark — move toward the light",
                why: onFace ? "Skin that's underexposed loses its true tone, and lifting it later brings up noise instead."
                            : "There isn't enough light on the work to hold detail.",
                moment: .lightingTooDark, severity: .failure)
        }
        if subject > CoachTuning.lumaTooBright {
            return CoachSignal(
                score: 0.4,
                message: onFace ? "Their face is blown out — turn away from the bright light"
                                : "Blown out — turn away from the bright light",
                why: "Clipped highlights are gone for good — there's nothing left in the file to pull back.",
                moment: .lightingBlownOut, severity: .failure)
        }
        // Score falls off smoothly away from the ideal exposure.
        let dist = abs(subject - CoachTuning.lumaIdeal)
        let score = max(0.6, 1.0 - dist * CoachTuning.lumaFalloff)
        return CoachSignal(score: score, message: nil)
    }
}

// MARK: - Composition

/// Judges subject placement when a face is present (centering + headroom). Stays
/// neutral when there's no face so non-portrait services aren't nagged (pose +
/// saliency coaches cover those later).
///
/// When the pro has the publish-crop guide on, every rule below is evaluated
/// INSIDE the 9:16 box rather than over the full 3:4 sensor frame. The camera
/// composes for the sensor and publishes to the feed; judging the sensor frame
/// let the coach call a shot perfectly composed — green ring, auto-capture
/// fires — while the published crop took the sides off it.
struct CompositionCoach: ShotCoach {
    let category: CoachCategory = .composition

    func evaluate(_ ctx: FrameContext) -> CoachSignal {
        let expects = ctx.expectations
        let crop = ctx.cropGuide

        // Fill the frame — the #1 amateur mistake is standing too far back.
        // Judged against the current shot's band when the guide sets one
        // (a detail shot wants much more fill than a portrait), else the
        // global floor. Detail/macro shots skip the floor — partial subjects
        // are the point. Inside the crop when there is one: filling the sensor
        // frame is not the same as filling what ships.
        if let fill = crop == nil ? ctx.subjectFill : ctx.cropSubjectFill {
            let closer = "Move in closer — fill the frame"
            let closerWhy = crop == nil
                ? "Standing too far back is the difference between a photo of a person and a photo of a room."
                : "The 9:16 feed crop takes ~40% of the width off this — what looks filled here won't be once it's published."
            if let band = expects?.fillBand {
                if fill < band.lowerBound {
                    return CoachSignal(score: 0.5, message: closer, why: closerWhy, moment: .compositionTooFar)
                }
                if fill > band.upperBound {
                    return CoachSignal(
                        score: 0.55, message: "Too tight — step back a touch",
                        why: "This shot wants the same framing as its pair; too tight and the two stop being comparable.",
                        moment: .compositionTooClose)
                }
            } else if expects?.isDetail != true, fill < CoachTuning.minSubjectFill {
                return CoachSignal(score: 0.5, message: closer, why: closerWhy, moment: .compositionTooFar)
            }
        }

        // Face placement only when the face belongs in this shot: a stray
        // mirror face must not drive headroom rules on a back-of-cut.
        if expects?.face == .absent {
            return CoachSignal(score: 1.0, message: nil)
        }
        guard let frameFace = ctx.faceBounds else {
            if expects?.face == .required {
                return CoachSignal(
                    score: 0.6, message: "Frame their face for this shot",
                    why: "This step's whole job is the face — its pair on the other side of the booking has one.",
                    moment: .compositionFaceRequired)
            }
            return CoachSignal(score: 1.0, message: nil)
        }

        // Falling outside the publish crop is its own, nameable problem: the
        // subject IS in the picture the pro is looking at, and won't be in the
        // one that ships.
        if let crop {
            let center = CGPoint(x: frameFace.midX, y: frameFace.midY)
            guard crop.contains(center) else {
                return CoachSignal(
                    score: 0.45, message: "They’re outside the feed crop — center them",
                    why: "The bright box is what the feed publishes; anything outside it is cut off there even though you can see it here.",
                    moment: .compositionOffFrame)
            }
        }
        let face = crop.map { PublishCrop.inCropSpace(frameFace, crop: $0) } ?? frameFace

        let centerX = face.midX
        let topY = face.minY
        let midY = face.midY

        // Headroom: face too high (cramped top) or sitting too low.
        if topY < CoachTuning.minHeadroom {
            return CoachSignal(
                score: 0.45, message: "Leave a little headroom — lower the camera",
                why: "Hair cropped at the top of the frame reads as an accident rather than a choice.",
                moment: .compositionNoHeadroom)
        }
        if midY > CoachTuning.maxSubjectLow {
            return CoachSignal(
                score: 0.5, message: "Raise the camera — subject’s too low",
                why: "Empty space above the head pulls the eye away from the work.",
                moment: .compositionTooLow)
        }
        // Horizontal placement: comfortable near center or a third.
        let nearCenter = abs(centerX - 0.5) < CoachTuning.centerTolerance
        let nearThird = abs(centerX - 0.33) < CoachTuning.thirdTolerance
            || abs(centerX - 0.67) < CoachTuning.thirdTolerance
        if !nearCenter && !nearThird {
            return CoachSignal(
                score: 0.55, message: "Center your subject",
                why: "Sitting between centre and a third reads as neither — the eye can't settle.",
                moment: .compositionRecenter)
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
            return CoachSignal(
                score: 0.3, message: "Hold steady — shot looks soft",
                why: "Softness is the one thing no edit fixes, and it shows up full-size long after the shoot.",
                moment: .sharpnessHoldSteady, severity: .failure)
        }
        if s < CoachTuning.sharpnessSlightlySoft * factor {
            return CoachSignal(
                score: 0.6, message: "Tap to focus — a touch soft",
                why: "The camera may be focused behind them; a tap puts it on the work.",
                moment: .sharpnessTapToFocus)
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
            return CoachSignal(
                score: 0.5, message: "Busy background — find a cleaner backdrop",
                why: "Shelves and product bottles compete with the work for attention, and they crop badly.",
                moment: .backgroundBusy)
        }
        let score = max(0.7, 1.0 - clutter)
        return CoachSignal(score: score, message: nil)
    }
}

// MARK: - Pose

/// Pose geometry in aspect-corrected units — normalized deltas must be scaled
/// by the frame's w/h aspect before angles/distances mean anything physical.
/// Shared by the live PoseCoach (3:4 frame) and the reference-look analyzer
/// (the reference image's own aspect).
nonisolated enum PoseGeometry {
    /// The live camera's upright frame aspect (w/h, .photo preset).
    static let liveFrameAspect = 3.0 / 4.0

    /// Shoulder-line angle off level, in physical degrees. Nil without both
    /// shoulders.
    static func shoulderAngleDegrees(_ pose: PoseSignal, aspect: Double) -> Double? {
        guard let left = pose.joints[.leftShoulder],
              let right = pose.joints[.rightShoulder] else { return nil }
        let dx = (right.x - left.x) * aspect
        let dy = right.y - left.y
        guard abs(dx) > 1e-6 else { return nil }
        return atan2(dy, dx) * 180 / .pi
    }

    /// Euclidean distance in aspect-corrected (physical-ish) units.
    static func distance(_ a: CGPoint, _ b: CGPoint, aspect: Double) -> Double {
        let dx = (a.x - b.x) * aspect
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    static func faceWidth(_ face: CGRect, aspect: Double) -> Double { face.width * aspect }
    static func faceHeight(_ face: CGRect) -> Double { face.height }
}

/// Judges body framing (not clipping the subject at an edge) AND, when the
/// current shot declares pose rules (trending pack or reference look), whether
/// the subject is actually IN the pose — the directive engine behind "the
/// camera poses your client." Rules gate readiness, so guided auto-capture
/// literally waits for the pose. Neutral for head-and-shoulders work. Camera
/// tilt is judged by `LevelCoach`.
struct PoseCoach: ShotCoach {
    let category: CoachCategory = .pose

    func evaluate(_ ctx: FrameContext) -> CoachSignal {
        if let pose = ctx.pose, pose.edgeClipped {
            return CoachSignal(
                score: 0.5, message: "Subject’s getting clipped — pull back",
                why: "A shoulder or hand cut by the frame edge reads as a mistake, and there's no room left to crop.",
                moment: .poseClipped)
        }

        let rules = ctx.expectations?.poseRules ?? []
        if !rules.isEmpty {
            guard let pose = ctx.pose, !pose.joints.isEmpty else {
                // Can't see the body yet — hold readiness gently, don't nag.
                return CoachSignal(score: 0.75, message: nil)
            }
            // Surface the FIRST unmet rule (pack order = direction order).
            for rule in rules where !Self.satisfied(rule, pose: pose, ctx: ctx) {
                return CoachSignal(
                    score: 0.45, message: rule.tip,
                    why: "This shot's brief is a specific pose — the camera waits for it rather than shooting past it.")
            }
            return CoachSignal(score: 1.0, message: nil)
        }

        // No brief and nobody clipped: nothing to say, so nothing is charged.
        //
        // This used to return 0.9 the moment a body was detected — with NO
        // message. In a portrait session that is always, so it was a permanent
        // 0.06 readiness tax the pro could never clear and was never told
        // about. An unexplained standing penalty is a bug whichever way you
        // look at it; a coach with nothing to say scores like one.
        return CoachSignal(score: 1.0, message: nil)
    }

    // MARK: Rule evaluators

    private static func satisfied(_ rule: PoseRule, pose: PoseSignal, ctx: FrameContext) -> Bool {
        let aspect = PoseGeometry.liveFrameAspect
        switch rule.kind {
        case .bothHandsVisible:
            return pose.joints[.leftWrist] != nil && pose.joints[.rightWrist] != nil

        case .handNearFace:
            guard let face = ctx.faceBounds else { return false }
            let maxFaceHeights = rule.params["maxFaceHeights"] ?? 1.3
            let limit = maxFaceHeights * PoseGeometry.faceHeight(face)
            let center = CGPoint(x: face.midX, y: face.midY)
            return [pose.joints[.leftWrist], pose.joints[.rightWrist]]
                .compactMap { $0 }
                .contains { PoseGeometry.distance($0, center, aspect: aspect) <= limit }

        case .faceNearShoulder:
            guard let face = ctx.faceBounds else { return false }
            let maxFaceWidths = rule.params["maxFaceWidths"] ?? 1.1
            let limit = maxFaceWidths * PoseGeometry.faceWidth(face, aspect: aspect)
            let center = CGPoint(x: face.midX, y: face.midY)
            return [pose.joints[.leftShoulder], pose.joints[.rightShoulder]]
                .compactMap { $0 }
                .contains { PoseGeometry.distance($0, center, aspect: aspect) <= limit }

        case .shouldersTilted:
            guard let angle = PoseGeometry.shoulderAngleDegrees(pose, aspect: aspect) else { return false }
            return abs(angle) >= (rule.params["minDegrees"] ?? 6)

        case .shouldersLevel:
            guard let angle = PoseGeometry.shoulderAngleDegrees(pose, aspect: aspect) else { return false }
            return abs(angle) <= (rule.params["maxDegrees"] ?? 6)
        }
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
            return CoachSignal(
                score: 0.4, message: "Camera’s tilted \(dir) — straighten it",
                why: "Straightening it afterwards means cropping in, and the ends of the hair are usually what gets lost.",
                moment: .levelTilted, phraseCtx: CoachPhraseContext(direction: dir))
        }
        if off > CoachTuning.tiltWarnDegrees {
            return CoachSignal(
                score: 0.7, message: "Almost level — straighten up",
                why: "A couple of degrees is enough to read as “off” next to its before/after pair.",
                moment: .levelAlmostLevel)
        }
        return CoachSignal(score: 1.0, message: nil)
    }
}

// MARK: - Color (light quality / white balance)

/// Flags the light problems that wreck beauty color: mixed sources (the #1 culprit)
/// and a strong green/fluorescent or warm/yellow cast that misrepresents skin tone.
/// Neutral when it can't measure (no signal) so it never blocks readiness blindly.
///
/// The three signals now arrive measured on the segmented BACKGROUND wherever a
/// person is in frame (`ColorSignal.backgroundScoped`), so they describe the
/// colour of the LIGHT rather than the colour of the client's top. The
/// thresholds are unchanged — they were guessed against a confounded signal and
/// are re-measured in the salon pass, on this cleaner one.
struct ColorCoach: ShotCoach {
    let category: CoachCategory = .color

    func evaluate(_ ctx: FrameContext) -> CoachSignal {
        guard let color = ctx.color else { return CoachSignal(score: 1.0, message: nil) }

        // Mixed light first — it can't be fixed with one white-balance setting.
        if color.mixed > CoachTuning.mixedLightSpread {
            return CoachSignal(
                score: 0.45, message: "Mixed light — turn off the overheads",
                why: "Warm bulbs on one side and a cool window on the other can't both be corrected — one half of their skin will read wrong whatever you do after.",
                moment: .colorMixed)
        }
        if color.greenTint > CoachTuning.greenCastTint {
            return CoachSignal(
                score: 0.55, message: "Greenish light — switch to one clean source",
                why: "Fluorescent green sits right where skin tone lives, so it's the cast clients notice first.",
                moment: .colorGreenish)
        }
        if color.warmth > CoachTuning.warmCastWarmth {
            return CoachSignal(
                score: 0.6, message: "Warm/yellow light — daylight reads truer",
                why: "Warm light pushes blonde and ash tones yellow, which is the colour work the client paid for.",
                moment: .colorWarm)
        }
        // Small penalty for mild mixing; otherwise clean.
        let score = max(0.75, 1.0 - color.mixed)
        return CoachSignal(score: score, message: nil)
    }
}
