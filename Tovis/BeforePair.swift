// "Does this frame pair with its before?" — the RECOGNITION half of the
// before/after comparison (camera plan P5.3).
//
// Before/after IS the product, and the app already measures both halves of
// what makes a pair read as one comparison rather than two photographs:
// `LightMatch` compares the after's light against the before's stamp, and
// `ShotExpectations.matchingFraming` re-targets the framing rung at the
// before's OWN measured subject fill. Each half is coached separately, and
// each half says something when it is WRONG.
//
// Nothing has ever said the good news about the PAIR. The light half does
// confirm itself ("Light matches the before" — that line ships today); the
// framing half just stops complaining, and "the coach went quiet" is not the
// same sentence as "these two will read as one comparison". This is that
// sentence, and it is the only thing this file adds.
//
// 🔴 Nothing new is MEASURED here, and no threshold is INVENTED here. Both
// terms are comparisons that already run every frame, against numbers the
// BEFORE ITSELF supplied, through the tolerances the coaching already uses:
// `CoachTuning.lightMatchLuma/WarmthTolerance` for the light half and
// `BeforeShotMeasure.pairFillBand` — the very band `matchingFraming` coaches
// to — for the framing half. So the salon pass (§3.2/D3) moves the
// recognition and the coaching TOGETHER, and they cannot end up disagreeing
// about whether this frame pairs with its before.
//
// 🔴 It is a FACT, not a feeling. "This matches your before" is something the
// app measured; "you're doing great" is not, and the north star rules the
// second one out. The line names what matched so the pro can check it.
//
// 🔴 It touches NOTHING else. Readiness, the dimensions drawer, the focus
// ladder, the arbiter, the harvest gate and the speech scheduler are all
// untouched — this rides the lane's existing before/after transient tier,
// which is where the light half's confirmation already lives. A compliment
// that also moved the ring would be the coach lying about the photograph in
// the friendlier direction.
import Foundation

/// The before/after verdict the lane shows: today's light comparison, upgraded
/// to a PAIR verdict on the frames where the framing matches too.
enum BeforePair {
    /// One frame's answer. `label` is the canonical (Calm Mentor) text — a
    /// `CoachVoice` renders `moment` over it downstream, exactly as the light
    /// verdict has always been rendered at its call site.
    struct Verdict: Equatable, Sendable {
        let label: String
        let ok: Bool
        /// Both halves matched: the pair will read as one comparison.
        let paired: Bool
        let moment: CoachMoment
        /// "before" or "reference" — what the light half is comparing against,
        /// carried so the render doesn't have to re-derive it.
        let noun: String
    }

    /// The canonical recognition sentence.
    ///
    /// It names the two things that matched rather than saying "matched",
    /// because a pro who cannot see WHAT the coach checked has been given a
    /// compliment instead of a measurement — and because these are the exact
    /// two words the rest of the coach already uses for them (`CoachCategory`
    /// `.lighting` / `.composition` speak as "Light" and "Framing").
    static let pairedLabel = "Light and framing match the before"

    /// Today's light verdict, upgraded when this frame ALSO fills like its
    /// before.
    ///
    /// `pairing` is nil for a "match a look" reference: that is a picture the
    /// pro admired, not the other half of this booking's pair, and its brief
    /// carries its own framing target. The light verdict then passes through
    /// byte-for-byte, which is what ships today.
    ///
    /// `liveFill` MUST be `FrameContext.judgedFill` — the fill
    /// `CompositionCoach` judged this frame by — not a fill of this layer's
    /// own choosing. That is what makes it impossible for the lane to show
    /// "Too tight — step back a touch" and "Light and framing match the
    /// before" about one frame.
    ///
    /// ⚠️ PRE-EXISTING SKEW, inherited deliberately and NOT introduced here:
    /// with the publish-crop guide ON, `judgedFill` is a fraction of the 9:16
    /// CROP while `pairFillBand` is derived from the before stamp's
    /// WHOLE-FRAME fill (`BeforeShotMeasure.measureSync` measures with
    /// `cropGuide: nil`). Those are different quantities — the crop is 0.75 of
    /// the frame's width — so above a before-fill of about 0.39 an after
    /// framed IDENTICALLY already reads as "too tight" to `CompositionCoach`
    /// today. Recognition inherits that rather than contradicting it: a coach
    /// that is consistently wrong is recoverable, a coach that argues with
    /// itself on screen is not. Written up with the arithmetic in
    /// docs/camera-tuning-bench.md; fixing it means measuring the stamp's
    /// crop-space fill too, which moves the "too far / too tight" thresholds
    /// and belongs with the salon pass (§3.2/D3), not here.
    static func verdict(live: LightMatch.Reading, target: LightMatch.Reading,
                        noun: String, pairing: BeforeShotStamp?,
                        liveFill: Double?, isDetail: Bool) -> Verdict {
        let light = LightMatch.verdict(live: live, target: target, noun: noun)
        let unpaired = Verdict(label: light.label, ok: light.ok, paired: false,
                               moment: light.moment, noun: noun)
        guard light.ok, let stamp = pairing, let liveFill,
              let band = BeforeShotMeasure.pairFillBand(of: stamp, isDetail: isDetail),
              band.contains(liveFill)
        else { return unpaired }
        return Verdict(label: pairedLabel, ok: true, paired: true,
                       moment: .pairedWithBefore, noun: noun)
    }
}

/// WHEN the lane says a before/after verdict, out of a stream of frames.
///
/// Pure and clock-injected so the question this whole step turns on — "is the
/// recognition a nag wearing a compliment's clothes?" — is answered by tests
/// rather than by shooting a session. Same shape as `CoachBackOff` (#360) and
/// `CoachHarvestGate` (#357), and for the same reason.
///
/// Two rules, and the first one is "change nothing that already ships":
///
///  1. The LIGHT verdict fires exactly when it fires today — on a change of
///     `ok`, and never on a steady state. Byte-for-byte the old behaviour, so
///     a pro who never reaches parity hears what they hear now.
///  2. The PAIR is recognized on the TRANSITION into parity, once — the shape
///     the focus ladder's `advanced`/`cleared` uses. It has to be its own
///     trigger rather than riding `ok`, because parity is reached in two moves
///     far more often than one: the pro fixes the light (that fires), and
///     moves in ten seconds later (that would fire nothing). Recognition on
///     every matching frame would be a nag wearing a compliment's clothes.
///
/// Re-crossing is floored by `CoachTuning.settleLineMinInterval` — the knob
/// that already exists for exactly this ("readiness flickering at the
/// threshold can't re-speak it every crossing"), reused rather than joined by
/// a fourth one. A frame hovering on the edge of the before's fill band is the
/// same problem in a different rung.
///
/// Dropping OUT of parity says nothing at all. The framing rung's own tip is
/// what the pro needs then, and re-announcing "light matches" underneath it
/// would be the coach talking about the half that isn't the problem.
struct BeforePairAnnouncer {
    private var lastOK: Bool?
    private var lastPaired = false
    private var lastRecognitionAt: Date?

    /// The verdict to put on the lane this frame, or nil for "say nothing".
    mutating func announcement(for verdict: BeforePair.Verdict, now: Date)
        -> BeforePair.Verdict? {
        let okChanged = verdict.ok != lastOK
        let newlyPaired = verdict.paired && !lastPaired
        lastOK = verdict.ok
        defer { lastPaired = verdict.paired }

        if okChanged {
            // The light half changed its mind — today's line, today's timing.
            // If it landed on parity, that IS the recognition, so it starts
            // the floor rather than being followed by a second line.
            if verdict.paired { lastRecognitionAt = now }
            return verdict
        }
        guard newlyPaired else { return nil }
        let since = lastRecognitionAt.map { now.timeIntervalSince($0) }
            ?? .greatestFiniteMagnitude
        guard since >= CoachTuning.settleLineMinInterval else { return nil }
        lastRecognitionAt = now
        return verdict
    }

    /// The pro moved to a DIFFERENT before (the next guided step, or a manual
    /// cycle through the references): the pair being judged is no longer the
    /// one already recognized, so recognition re-arms.
    ///
    /// Deliberately does NOT clear `lastOK` — the light half's timing is not
    /// this step's to change — nor `lastRecognitionAt`, so cycling references
    /// cannot be used to fire the line over and over.
    mutating func newPairing() {
        lastPaired = false
    }
}
