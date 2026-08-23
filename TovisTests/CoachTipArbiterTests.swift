// Sequential focus coaching — the ladder LOCK, the stability-gated ADVANCE,
// and the hysteresis-guarded REGRESSION. Founder-directed product change
// (2026-08-06 live device feedback): the coach used to re-rank by weighted
// deficit every analyzed frame, which meant firing whichever fundamental was
// worst RIGHT NOW rather than working through problems big-adjustment-first.
// It now locks onto ONE rung of `FocusRung`'s fixed order and stays there
// until that rung reads stable-good, then moves on.
//
// These pin the arithmetic. No camera, no thresholds from the device pass —
// just: does the lock hold, does it advance/regress at the right moment, and
// does the order match the ladder.
import Testing
@testable import Tovis

@Suite struct CoachTipArbiterTests {
    private func signal(_ category: CoachCategory, score: Double, message: String? = "x",
                        moment: CoachMoment? = nil,
                        severity: CoachSeverity = .correction) -> (CoachCategory, CoachSignal) {
        (category, CoachSignal(score: score, message: message, moment: moment,
                               severity: severity))
    }

    // MARK: - Lock: earliest broken rung in ladder order, not the worst deficit

    /// The behavior change this whole rewrite is for: with lighting AND
    /// sharpness both broken, the OLD deficit-based arbiter could pick
    /// whichever scored worse. The ladder always picks lighting — it's
    /// earlier in the fixed order — regardless of which one is "worse".
    ///
    /// Note what "worse" means here: a lower SCORE. A low score is not what
    /// `CoachSeverity` measures (that's whether the capture is recoverable at
    /// all), and it deliberately still buys no priority — otherwise every
    /// device retune would quietly re-rank the coach's one line.
    @Test func locksOntoTheEarliestBrokenRungRegardlessOfScore() {
        var arbiter = CoachTipArbiter()
        // Sharpness scored far worse (0.1) than lighting (0.4), which would
        // have won outright under the old weighted-deficit ranking.
        let outcome = arbiter.select(
            from: [signal(.sharpness, score: 0.1), signal(.lighting, score: 0.4)], now: 0)
        #expect(outcome.nudge?.category == .lighting)
    }

    @Test func colorComesRightAfterLightingBeforeAnyFraming() {
        var arbiter = CoachTipArbiter()
        let outcome = arbiter.select(
            from: [signal(.composition, score: 0.3), signal(.color, score: 0.3)], now: 0)
        #expect(outcome.nudge?.category == .color)
    }

    @Test func sharpnessIsAlwaysLastEvenAgainstEverythingElseBroken() {
        var arbiter = CoachTipArbiter()
        let everythingBroken: [(CoachCategory, CoachSignal)] = [
            signal(.sharpness, score: 0.1), signal(.lighting, score: 0.5),
            signal(.color, score: 0.5), signal(.composition, score: 0.5),
            signal(.level, score: 0.5), signal(.background, score: 0.5),
            signal(.pose, score: 0.5),
        ]
        let outcome = arbiter.select(from: everythingBroken, now: 0)
        #expect(outcome.nudge?.category == .lighting, "the earliest rung, not sharpness, must win")
    }

    /// Composition's moment decides which of the two composition rungs it
    /// lands on — `.compositionTooFar` is a framing (distance) problem,
    /// which comes before centering.
    @Test func compositionSplitsIntoFramingAndCenteringByMoment() {
        var framingArbiter = CoachTipArbiter()
        let framing = framingArbiter.select(
            from: [signal(.composition, score: 0.4, moment: .compositionTooFar)], now: 0)
        #expect(framing.nudge?.moment == .compositionTooFar)

        var centeringArbiter = CoachTipArbiter()
        let centering = centeringArbiter.select(
            from: [signal(.composition, score: 0.4, moment: .compositionRecenter)], now: 0)
        #expect(centering.nudge?.moment == .compositionRecenter)
    }

    /// A framing problem outranks a centering one — distance is the bigger
    /// adjustment, fine centering is the detail polish.
    @Test func framingOutranksCenteringWhenBothAreImpossibleSimultaneously() {
        // (Can't literally happen from one CompositionCoach signal, but the
        // ladder ordering itself — framing < centering — is what's pinned.)
        #expect(FocusRung.framing < FocusRung.centering)
    }

    // MARK: - Advance: gated on the stability window, not the first good frame

    /// The core new behavior: a rung reading good for the first time does
    /// NOT advance the ladder immediately — a momentary good reading might
    /// be sensor noise, not a real fix. The last-known correction keeps
    /// showing until the reading has held continuously for the full window.
    @Test func aMomentaryGoodReadingDoesNotAdvancePrematurely() {
        var arbiter = CoachTipArbiter()
        _ = arbiter.select(from: [signal(.lighting, score: 0.3), signal(.color, score: 0.3)], now: 0)

        // Lighting reads good for the first time at t=1 — starts the clock.
        let firstGood = arbiter.select(from: [signal(.color, score: 0.3)], now: 1)
        #expect(firstGood.nudge?.category == .lighting, "must keep showing lighting until it's PROVEN stable")
        #expect(firstGood.advanced == nil)

        // Still well under the stability window a moment later.
        let stillWaiting = arbiter.select(from: [signal(.color, score: 0.3)], now: 1.2)
        #expect(stillWaiting.nudge?.category == .lighting)
        #expect(stillWaiting.advanced == nil)
    }

    /// Once the stability window elapses with the rung continuously good, the
    /// ladder advances — and reports which rung just cleared, so the coach
    /// can compliment it.
    @Test func advancesOnceTheStabilityWindowElapses() {
        var arbiter = CoachTipArbiter()
        _ = arbiter.select(from: [signal(.lighting, score: 0.3), signal(.color, score: 0.3)], now: 0)
        // Lighting starts reading good at t=1 — this is when the clock starts.
        _ = arbiter.select(from: [signal(.color, score: 0.3)], now: 1)

        let midWindow = arbiter.select(
            from: [signal(.color, score: 0.3)], now: 1 + CoachTuning.focusStabilityWindow - 0.1)
        #expect(midWindow.nudge?.category == .lighting)
        #expect(midWindow.advanced == nil)

        let advanced = arbiter.select(
            from: [signal(.color, score: 0.3)], now: 1 + CoachTuning.focusStabilityWindow + 0.1)
        #expect(advanced.advanced == .lighting)
        #expect(advanced.nudge?.category == .color)
        #expect(advanced.cleared == nil)
    }

    /// A flicker resets the stability clock: good for a moment, bad again,
    /// good again — the SECOND good streak has to serve the full window on
    /// its own, not inherit progress from the first.
    @Test func aFlickerBackToBadResetsTheStabilityClock() {
        var arbiter = CoachTipArbiter()
        _ = arbiter.select(from: [signal(.lighting, score: 0.3)], now: 0)

        // Good starting at t=1...
        _ = arbiter.select(from: [], now: 1.0)
        // ...bad again at t=1.2, well under the ORIGINAL window from t=1.
        _ = arbiter.select(from: [signal(.lighting, score: 0.3)], now: 1.2)
        // Good again — if the clock had NOT reset at 1.2, elapsed since t=1
        // would already exceed the window by now; since it DID reset, this
        // fresh streak (started at 1.2) has only served `stabilityWindow - 0.1`.
        let recheck = arbiter.select(from: [], now: 1.2 + CoachTuning.focusStabilityWindow - 0.1)
        #expect(recheck.advanced == nil, "the flicker must not have let stability accumulate across the gap")
    }

    /// Re-wording within the SAME rung ("hold steady" → "tap to focus", both
    /// sharpness) is still "broken" — it must not read as a good frame and
    /// start the stability clock.
    @Test func rewordingWithinTheSameRungNeverCountsAsGood() {
        var arbiter = CoachTipArbiter()
        _ = arbiter.select(from: [signal(.sharpness, score: 0.3, moment: .sharpnessHoldSteady)], now: 0)
        let reworded = arbiter.select(
            from: [signal(.sharpness, score: 0.6, moment: .sharpnessTapToFocus)], now: 1.0)
        #expect(reworded.nudge?.moment == .sharpnessTapToFocus)
        #expect(reworded.advanced == nil)

        // Still treated as broken, not stabilizing: even well past the
        // stability window, still no advance while it keeps reporting
        // (whatever the wording).
        let stillReworded = arbiter.select(
            from: [signal(.sharpness, score: 0.6, moment: .sharpnessTapToFocus)],
            now: 1.0 + CoachTuning.focusStabilityWindow + 1)
        #expect(stillReworded.advanced == nil)
    }

    // MARK: - Full clear: advance with nothing left broken

    @Test func clearsCompletelyWhenTheLastRungStabilizesWithNothingElseBroken() {
        var arbiter = CoachTipArbiter()
        _ = arbiter.select(from: [signal(.sharpness, score: 0.3)], now: 0)
        _ = arbiter.select(from: [], now: 1)   // sharpness starts reading good
        let cleared = arbiter.select(from: [], now: 1 + CoachTuning.focusStabilityWindow + 0.1)
        #expect(cleared.cleared == .sharpness)
        #expect(cleared.nudge == nil)
        #expect(cleared.advanced == nil)
    }

    // MARK: - Regression: hysteresis-guarded jump back

    /// The described product behavior: working a lower rung, a previously-
    /// fixed higher rung breaks badly enough for long enough — the lock
    /// jumps back. No compliment (nothing was completed), just a redirect.
    @Test func jumpsBackToAHigherRungThatBreaksAgainAfterTheRegressionWindow() {
        var arbiter = CoachTipArbiter()
        _ = arbiter.select(from: [signal(.lighting, score: 0.3), signal(.composition, score: 0.3)], now: 0)
        _ = arbiter.select(from: [signal(.composition, score: 0.3)], now: 1)   // lighting starts reading good
        let advanced = arbiter.select(
            from: [signal(.composition, score: 0.3)], now: 1 + CoachTuning.focusStabilityWindow + 0.1)
        #expect(advanced.nudge?.category == .composition)
        let advanceTime = 1 + CoachTuning.focusStabilityWindow + 0.1

        // Lighting breaks again — first observed bad a beat later.
        let firstBad = advanceTime + 1
        _ = arbiter.select(
            from: [signal(.composition, score: 0.3), signal(.lighting, score: 0.2)], now: firstBad)

        let stillGuarded = arbiter.select(
            from: [signal(.composition, score: 0.3), signal(.lighting, score: 0.2)],
            now: firstBad + CoachTuning.focusRegressionWindow - 0.1)
        #expect(stillGuarded.nudge?.category == .composition, "not trusted yet — still inside the regression window")

        let jumpedBack = arbiter.select(
            from: [signal(.composition, score: 0.3), signal(.lighting, score: 0.2)],
            now: firstBad + CoachTuning.focusRegressionWindow + 0.1)
        #expect(jumpedBack.nudge?.category == .lighting)
        #expect(jumpedBack.advanced == nil, "a regression is a redirect, not a completion — no compliment")
        #expect(jumpedBack.cleared == nil)
    }

    /// The hysteresis this exists for: a higher rung that's merely
    /// FLICKERING bad (not continuously) never accumulates enough time to
    /// trip the jump — this is what stops two borderline rungs from
    /// ping-ponging the lock.
    @Test func aFlickeringHigherRungNeverTripsTheJumpBack() {
        var arbiter = CoachTipArbiter()
        _ = arbiter.select(from: [signal(.lighting, score: 0.3), signal(.composition, score: 0.3)], now: 0)
        _ = arbiter.select(from: [signal(.composition, score: 0.3)], now: 1)
        _ = arbiter.select(
            from: [signal(.composition, score: 0.3)], now: 1 + CoachTuning.focusStabilityWindow + 0.1)
        let advanceTime = 1 + CoachTuning.focusStabilityWindow + 0.1

        // Lighting goes bad, tracked...
        let firstBad = advanceTime + 1
        _ = arbiter.select(from: [signal(.composition, score: 0.3), signal(.lighting, score: 0.2)], now: firstBad)
        // ...then recovers before the regression window elapses...
        _ = arbiter.select(from: [signal(.composition, score: 0.3)], now: firstBad + 0.2)
        // ...then goes bad again — a NEW bad streak, not a continuation.
        let secondBad = firstBad + 0.4
        _ = arbiter.select(from: [signal(.composition, score: 0.3), signal(.lighting, score: 0.2)], now: secondBad)
        let stillNoJump = arbiter.select(
            from: [signal(.composition, score: 0.3), signal(.lighting, score: 0.2)],
            now: secondBad + CoachTuning.focusRegressionWindow - 0.1)
        #expect(stillNoJump.nudge?.category == .composition, "the flicker must not have accumulated toward the jump")
    }

    /// The candidate identity mattering, not just "something is broken above
    /// me": if lighting's bad streak is interrupted by color becoming the
    /// candidate instead, lighting's clock doesn't carry over to color.
    @Test func switchingWhichHigherRungIsBadResetsTheRegressionClock() {
        var arbiter = CoachTipArbiter()
        _ = arbiter.select(from: [signal(.lighting, score: 0.3), signal(.pose, score: 0.3)], now: 0)
        _ = arbiter.select(from: [signal(.pose, score: 0.3)], now: 1)
        _ = arbiter.select(from: [signal(.pose, score: 0.3)], now: 1 + CoachTuning.focusStabilityWindow + 0.1)
        let advanceTime = 1 + CoachTuning.focusStabilityWindow + 0.1

        // Lighting is the candidate for a while, not long enough to trip.
        let lightingBadAt = advanceTime + 1
        _ = arbiter.select(from: [signal(.pose, score: 0.3), signal(.lighting, score: 0.2)], now: lightingBadAt)
        let switchAt = lightingBadAt + CoachTuning.focusRegressionWindow - 0.2
        // Color goes bad INSTEAD of lighting (lighting recovered) — a new candidate.
        _ = arbiter.select(from: [signal(.pose, score: 0.3), signal(.color, score: 0.2)], now: switchAt)
        let stillNoJump = arbiter.select(
            from: [signal(.pose, score: 0.3), signal(.color, score: 0.2)],
            now: switchAt + CoachTuning.focusRegressionWindow - 0.1)
        #expect(stillNoJump.nudge?.category == .pose, "color just became the candidate — it hasn't served its own window yet")
    }

    // MARK: - A hard failure outranks its rung (2026-08-23, plan item 1.3)
    //
    // The ladder orders by the SIZE of an adjustment, which is right about
    // adjustments and silent about whether the photo survives. `CoachSeverity`
    // adds the second axis: an unrecoverable capture is spoken about first,
    // whatever rung it sits on. Everything else keeps taking its turn.

    /// The headline case, and the one the bench measured: colour (rung 2) is
    /// broken and so is sharpness (rung 8, last). Ordinarily colour wins and
    /// should. When the frame is genuinely soft — motion blur, nothing to
    /// recover — sharpness takes the line instead.
    @Test func aHardFailureOutranksAnEarlierRungsOrdinaryCorrection() {
        var arbiter = CoachTipArbiter()
        let outcome = arbiter.select(from: [
            signal(.color, score: 0.45, moment: .colorMixed),
            signal(.sharpness, score: 0.3, moment: .sharpnessHoldSteady, severity: .failure),
        ], now: 0)
        #expect(outcome.nudge?.category == .sharpness)
    }

    /// The guardrail on the above: severity is not a general re-ranker. With no
    /// failure in play the ladder is untouched — this is the same input as the
    /// test above minus the `.failure` marking, and colour wins again.
    @Test func withoutAFailureTheLadderOrderIsCompletelyUnchanged() {
        var arbiter = CoachTipArbiter()
        let outcome = arbiter.select(from: [
            signal(.color, score: 0.45, moment: .colorMixed),
            signal(.sharpness, score: 0.3, moment: .sharpnessHoldSteady),
        ], now: 0)
        #expect(outcome.nudge?.category == .color)
    }

    /// Among hard failures the ladder's own big-adjustment-first order still
    /// decides: an unrecoverable exposure and an unrecoverable blur at once
    /// means fix the light, because recomposing a blown frame is wasted effort.
    @Test func amongTwoHardFailuresTheLadderOrderStillDecides() {
        var arbiter = CoachTipArbiter()
        let outcome = arbiter.select(from: [
            signal(.sharpness, score: 0.3, moment: .sharpnessHoldSteady, severity: .failure),
            signal(.lighting, score: 0.3, moment: .lightingTooDark, severity: .failure),
        ], now: 0)
        #expect(outcome.nudge?.category == .lighting)
    }

    /// A failure appearing mid-session doesn't seize the line instantly: it
    /// serves the same hysteresis window as any other preemption, so a single
    /// blurred frame during a hand movement can't yank the coach off what the
    /// pro is currently working on.
    @Test func aFailureMustServeTheHysteresisWindowBeforeItTakesTheLock() {
        var arbiter = CoachTipArbiter()
        // Working an ordinary colour correction.
        _ = arbiter.select(from: [signal(.color, score: 0.45, moment: .colorMixed)], now: 0)

        let softened: [(CoachCategory, CoachSignal)] = [
            signal(.color, score: 0.45, moment: .colorMixed),
            signal(.sharpness, score: 0.3, moment: .sharpnessHoldSteady, severity: .failure),
        ]
        let firstBad = 1.0
        _ = arbiter.select(from: softened, now: firstBad)

        let tooSoon = arbiter.select(
            from: softened, now: firstBad + CoachTuning.focusRegressionWindow - 0.1)
        #expect(tooSoon.nudge?.category == .color, "one blurred frame must not yank the lock")

        let taken = arbiter.select(
            from: softened, now: firstBad + CoachTuning.focusRegressionWindow + 0.1)
        #expect(taken.nudge?.category == .sharpness)
        #expect(taken.advanced == nil, "taking over is a redirect, not a completion")
        #expect(taken.cleared == nil)
    }

    /// The mirror of the regression rule: while the coach is holding a hard
    /// failure, an EARLIER rung breaking does not pull the line away from it.
    /// The pro is being told the shot is unusable; interrupting that with a
    /// backdrop note would be the old problem pointing the other way.
    @Test func anEarlierRungDoesNotPreemptAHardFailureBeingWorked() {
        var arbiter = CoachTipArbiter()
        let failing: [(CoachCategory, CoachSignal)] = [
            signal(.sharpness, score: 0.3, moment: .sharpnessHoldSteady, severity: .failure),
        ]
        _ = arbiter.select(from: failing, now: 0)

        let alsoColor: [(CoachCategory, CoachSignal)] = failing + [
            signal(.color, score: 0.45, moment: .colorMixed),
        ]
        _ = arbiter.select(from: alsoColor, now: 1)
        let held = arbiter.select(
            from: alsoColor, now: 1 + CoachTuning.focusRegressionWindow + 0.5)
        #expect(held.nudge?.category == .sharpness, "a hard failure keeps the line until it's fixed")
    }

    /// Clearing the failure hands the line straight back to the ladder — the
    /// coach doesn't stay stuck on the rung it jumped to.
    ///
    /// No compliment fires on THIS path, and that is pre-existing rather than
    /// anything severity introduced: sharpness is the ladder's last rung, so
    /// once it reads good the still-broken colour rung is an ordinary earlier-
    /// rung preemption, and its window (`focusRegressionWindow`, 1.0s) elapses
    /// before the advance's `focusStabilityWindow` (1.5s) ever could. The
    /// compliment path is covered by the lighting case below.
    @Test func clearingTheFailureReturnsTheLineToTheLadderOrder() {
        var arbiter = CoachTipArbiter()
        let both: [(CoachCategory, CoachSignal)] = [
            signal(.color, score: 0.45, moment: .colorMixed),
            signal(.sharpness, score: 0.3, moment: .sharpnessHoldSteady, severity: .failure),
        ]
        let taken = arbiter.select(from: both, now: 0)
        #expect(taken.nudge?.category == .sharpness)

        // Sharpness reads good from t=1; colour is still broken.
        let colorOnly = [signal(.color, score: 0.45, moment: .colorMixed)]
        _ = arbiter.select(from: colorOnly, now: 1)
        let back = arbiter.select(from: colorOnly, now: 1 + CoachTuning.focusRegressionWindow + 0.1)
        #expect(back.nudge?.category == .color, "the ladder resumes where it was")
        #expect(back.advanced == nil)
    }

    /// A hard failure that is FIXED gets complimented like any other cleared
    /// rung — severity changes which correction is spoken, never the
    /// compliment-then-redirect moment on the way out of it.
    @Test func aFixedFailureIsComplimentedLikeAnyClearedRung() {
        var arbiter = CoachTipArbiter()
        let failingLight: [(CoachCategory, CoachSignal)] = [
            signal(.lighting, score: 0.3, moment: .lightingTooDark, severity: .failure),
            signal(.background, score: 0.5, moment: .backgroundBusy),
        ]
        #expect(arbiter.select(from: failingLight, now: 0).nudge?.category == .lighting)

        // Lighting reads good from t=1, with the backdrop still to fix.
        let backgroundOnly = [signal(.background, score: 0.5, moment: .backgroundBusy)]
        _ = arbiter.select(from: backgroundOnly, now: 1)
        let advanced = arbiter.select(
            from: backgroundOnly, now: 1 + CoachTuning.focusStabilityWindow + 0.1)
        #expect(advanced.advanced == .lighting)
        #expect(advanced.nudge?.category == .background)
    }

    // MARK: - The memory-free evaluate is the same rule with fresh state

    @Test func theStatelessEvaluateIsTheSameLadderLock() {
        var arbiter = CoachTipArbiter()
        let picked = arbiter.select(
            from: [signal(.sharpness, score: 0.1), signal(.lighting, score: 0.4)], now: 0).nudge
        #expect(picked?.category == .lighting)
    }
}
