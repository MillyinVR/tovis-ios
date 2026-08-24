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
import CoreGraphics
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

    // MARK: - Room memory: retiring a tip the pro can't act on (P4.1)
    //
    // The one thing in this type that changes what is DECIDED rather than how
    // it is worded — so these pin the guarantees that come with that, not just
    // the happy path.

    @Test func aRetiredRoomTipLosesTheLineToTheNextBrokenRung() {
        var arbiter = CoachTipArbiter()
        arbiter.dismissed = [.colorMixed]
        let outcome = arbiter.select(
            from: [signal(.color, score: 0.45, moment: .colorMixed),
                   signal(.composition, score: 0.5, moment: .compositionTooFar)],
            now: 0)
        #expect(outcome.nudge?.moment == .compositionTooFar,
                "the coach must move on to the next thing, not go quiet")
    }

    /// The coach doesn't fall silent about the whole frame just because the
    /// one thing it was locked on has been retired — which is exactly what
    /// suppressing downstream (in `CoachEngine.apply`) would have done.
    @Test func retiringTheOnlyBrokenRungLeavesNothingToSayRatherThanAStaleLine() {
        var arbiter = CoachTipArbiter()
        arbiter.dismissed = [.backgroundBusy]
        let outcome = arbiter.select(
            from: [signal(.background, score: 0.5, moment: .backgroundBusy)], now: 0)
        #expect(outcome.nudge == nil)
        #expect(outcome.cleared == nil, "nothing was FIXED — there is just nothing left to say")
    }

    /// ⚠️ The rule the plan asked to be argued explicitly. A `.failure` is a
    /// capture no edit recovers; "the light is behind them and this frame is
    /// lost" is not the same kind of statement as "the overheads stay on
    /// here", and the arbiter refuses to retire it even when the stored set
    /// says otherwise.
    @Test func aHardFailureIsNeverRetiredHoweverTheSetIsSpelled() {
        var arbiter = CoachTipArbiter()
        arbiter.dismissed = [.lightingBacklit, .sharpnessHoldSteady]
        let outcome = arbiter.select(
            from: [signal(.lighting, score: 0.4, moment: .lightingBacklit, severity: .failure),
                   signal(.composition, score: 0.5, moment: .compositionTooFar)],
            now: 0)
        #expect(outcome.nudge?.moment == .lightingBacklit)
    }

    /// A tip that is retired while its own rung is LOCKED must let the lock go
    /// this frame. Waiting the stability window out instead would keep the
    /// retired sentence on screen for 1.5s and then compliment the pro on the
    /// colour it is still wrong about — the ladder reading "fixed" off an
    /// absence that is suppression.
    @Test func aDismissalLandingOnTheLockedRungRedirectsWithoutAComplimentOrADelay() {
        var arbiter = CoachTipArbiter()
        let broken: [(CoachCategory, CoachSignal)] = [
            signal(.color, score: 0.45, moment: .colorMixed),
            signal(.composition, score: 0.5, moment: .compositionTooFar),
        ]
        #expect(arbiter.select(from: broken, now: 0).nudge?.moment == .colorMixed)
        arbiter.dismissed = [.colorMixed]
        let after = arbiter.select(from: broken, now: 0.1)
        #expect(after.nudge?.moment == .compositionTooFar, "same frame, not after the stability window")
        #expect(after.advanced == nil, "colour was retired, not fixed — nothing to compliment")
        #expect(after.cleared == nil)
    }

    /// Suppression is about the WORDS. Readiness is a weighted mean over the
    /// signals, computed before the arbiter is asked anything — a retired tip
    /// is still a real deficit and the ring still knows.
    @Test func retiringATipDoesNotMoveReadinessOrTheDimensionsDrawer() {
        let coaches: [ShotCoach] = [ColorCoach(), BackgroundCoach()]
        let ctx = FrameContext(
            avgLuma: 0.5, faceBounds: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.4),
            faceLuma: 0.5, backgroundLuma: 0.5, sharpness: 1,
            backgroundClutter: 1, subjectFill: 0.4, pose: nil, deviceTilt: 0,
            color: ColorSignal(mixed: 1, greenTint: 0, warmth: 0, backgroundScoped: true),
            expectations: nil)
        var plain = CoachTipArbiter()
        let before = CoachAggregate.evaluate(coaches, ctx, arbiter: &plain, now: 0)
        var retired = CoachTipArbiter()
        retired.dismissed = [.colorMixed]
        let after = CoachAggregate.evaluate(coaches, ctx, arbiter: &retired, now: 0)

        #expect(after.readiness == before.readiness, "the ring must still count the deficit")
        #expect(after.statuses.map(\.score) == before.statuses.map(\.score))
        #expect(after.statuses.map(\.message) == before.statuses.map(\.message),
                "the drawer is the surface the pro opened to ask why it won't go green")
        #expect(before.nudge?.moment == .colorMixed)
        #expect(after.nudge?.moment != .colorMixed, "only the one on-screen line changes")
    }

    /// The memory-free overload — what the offline tuning bench and every
    /// pinned `CoachReadinessTests` assertion run through — carries no
    /// dismissals at all, so neither can drift from canonical behaviour.
    @Test func theMemoryFreeOverloadNeverSuppressesAnything() {
        var fresh = CoachTipArbiter()
        #expect(fresh.dismissed.isEmpty)
        _ = fresh.select(from: [signal(.color, score: 0.45, moment: .colorMixed)], now: 0)
        #expect(fresh.dismissed.isEmpty)
    }

    // MARK: - Backing off when repeating itself has stopped working (P4.3)
    //
    // The SECOND thing in this type that changes what is decided rather than
    // how it is worded, and — unlike a dismissal — it is the coach's OWN
    // inference rather than the pro's instruction. So these pin the same three
    // guarantees again, plus the two that are specific to it: silence is not
    // read as "fixed", and the score moving brings the words straight back.
    // The arithmetic itself lives in `CoachBackOffTests`.

    /// Drive one arbiter over `seconds` at the analyzer's real cadence.
    @discardableResult
    private func run(_ arbiter: inout CoachTipArbiter,
                     _ signals: [(CoachCategory, CoachSignal)],
                     from: Double, seconds: Double) -> CoachTipArbiter.Outcome? {
        let step = 1.0 / CoachTuning.analysisFPS
        var now = from
        var last: CoachTipArbiter.Outcome?
        while now <= from + seconds {
            last = arbiter.select(from: signals, now: now)
            now += step
        }
        return last
    }

    private var patience: Double { CoachBackOff.simplifyAfter }
    private var silence: Double { CoachBackOff.quietAfter }

    /// The shape of the whole step: say it, say it plainer, then stop saying it
    /// and coach the next thing instead.
    @Test func aStalledTipIsSaidPlainlyOnceAndThenHandsTheLineOn() {
        var arbiter = CoachTipArbiter()
        let broken: [(CoachCategory, CoachSignal)] = [
            signal(.color, score: 0.45, moment: .colorMixed),
            signal(.composition, score: 0.5, moment: .compositionTooFar),
        ]
        let early = run(&arbiter, broken, from: 0, seconds: patience - 2)
        #expect(early?.nudge?.moment == .colorMixed)
        #expect(early?.simplified == false, "still inside the coach's patience")

        let plainer = run(&arbiter, broken, from: patience, seconds: patience - 2)
        #expect(plainer?.nudge?.moment == .colorMixed, "same correction, about to be said plainer")
        #expect(plainer?.simplified == true)

        let after = run(&arbiter, broken, from: silence, seconds: 1)
        #expect(after?.nudge?.moment == .compositionTooFar,
                "the coach must move on to what the pro CAN change, not stand mute")
    }

    /// 🔴 The rule the plan asked to be decided and argued: going quiet is NOT
    /// the same as being fixed. Silence must never reach the ladder's
    /// stable-good path, or the coach would compliment the pro on the colour it
    /// is still wrong about — the same defect a dismissal on the locked rung
    /// had, reached by a different route.
    @Test func backingOffIsNeverHeardAsAComplimentOrAnAdvance() {
        var arbiter = CoachTipArbiter()
        let broken: [(CoachCategory, CoachSignal)] = [
            signal(.color, score: 0.45, moment: .colorMixed),
            signal(.composition, score: 0.5, moment: .compositionTooFar),
        ]
        run(&arbiter, broken, from: 0, seconds: silence - 1)
        let handover = run(&arbiter, broken, from: silence, seconds: 1)
        #expect(handover?.nudge?.moment == .compositionTooFar)
        #expect(handover?.advanced == nil, "colour was given up on, not solved")
        #expect(handover?.cleared == nil)
    }

    /// …and with nothing else broken, the lane simply goes quiet. No
    /// compliment, no stale line, and — because the ladder let the lock go
    /// rather than sitting on it silently — no reason the next thing that
    /// breaks can't be coached normally.
    @Test func backingOffOnTheOnlyBrokenRungLeavesNothingToSayRatherThanPraise() {
        var arbiter = CoachTipArbiter()
        let onlyColour = [signal(.color, score: 0.45, moment: .colorMixed)]
        run(&arbiter, onlyColour, from: 0, seconds: silence - 1)
        let quiet = run(&arbiter, onlyColour, from: silence, seconds: 1)
        #expect(quiet?.nudge == nil)
        #expect(quiet?.cleared == nil, "nothing was FIXED — the coach just stopped saying it")
        #expect(quiet?.advanced == nil)

        // The lock was released, so a NEW problem is still coached in full.
        let framing = arbiter.select(
            from: [signal(.color, score: 0.45, moment: .colorMixed),
                   signal(.composition, score: 0.5, moment: .compositionTooFar)],
            now: silence + 2)
        #expect(framing.nudge?.moment == .compositionTooFar)
    }

    /// ⚠️ Asked explicitly by the plan, and decided the same way #359 decided
    /// it for dismissal — but for a stronger reason. A `.failure` is a capture
    /// no edit recovers; going quiet about a photograph that is already lost
    /// leaves the pro shooting frames that do not exist. A dismissal is at
    /// least the PRO's judgement that a condition isn't theirs to fix; backing
    /// off is only the coach's own, so it gets less licence, not more.
    @Test func aHardFailureIsNeverBackedOffHoweverLongItHolds() {
        var arbiter = CoachTipArbiter()
        let lostFrame: [(CoachCategory, CoachSignal)] = [
            signal(.sharpness, score: 0.3, moment: .sharpnessHoldSteady, severity: .failure),
        ]
        run(&arbiter, lostFrame, from: 0, seconds: silence + 5)
        let still = arbiter.select(from: lostFrame, now: silence + 10)
        #expect(still.nudge?.moment == .sharpnessHoldSteady)
        #expect(still.simplified == false, "there is no plainer way to say a frame is lost")
    }

    /// A correction that ESCALATES into a hard failure takes its words back
    /// even after the coach had given up on it — the frame stopped being a
    /// preference and started being a loss.
    @Test func aRungThatEscalatesToAFailureTakesTheLineBackAfterBackingOff() {
        var arbiter = CoachTipArbiter()
        let softish = [signal(.sharpness, score: 0.6, moment: .sharpnessTapToFocus)]
        run(&arbiter, softish, from: 0, seconds: silence + 1)
        #expect(arbiter.select(from: softish, now: silence + 2).nudge == nil)

        let lost = [signal(.sharpness, score: 0.3, moment: .sharpnessHoldSteady,
                           severity: .failure)]
        #expect(arbiter.select(from: lost, now: silence + 3).nudge?.moment == .sharpnessHoldSteady)
    }

    /// The pro starting to act on the line is the whole signal. A score that
    /// moves brings the correction straight back, at full length.
    @Test func progressBringsABackedOffTipStraightBack() {
        var arbiter = CoachTipArbiter()
        let stuck: [(CoachCategory, CoachSignal)] = [
            signal(.composition, score: 0.45, moment: .compositionNoHeadroom),
            signal(.background, score: 0.5, moment: .backgroundBusy),
        ]
        run(&arbiter, stuck, from: 0, seconds: silence - 1)
        let handover = run(&arbiter, stuck, from: silence, seconds: 1)
        #expect(handover?.nudge?.moment == .backgroundBusy)

        // The pro raises the camera: composition moves 0.45 → 0.50, and the
        // centering rung outranks the backdrop, so it preempts back.
        let improving: [(CoachCategory, CoachSignal)] = [
            signal(.composition, score: 0.50, moment: .compositionTooLow),
            signal(.background, score: 0.5, moment: .backgroundBusy),
        ]
        let back = run(&arbiter, improving, from: silence + 2,
                       seconds: CoachTuning.focusRegressionWindow + 1)
        #expect(back?.nudge?.moment == .compositionTooLow)
        #expect(back?.simplified == false, "the patience was earned back in full")
    }

    /// Backing off is about the WORDS, exactly like a dismissal. Readiness is a
    /// weighted mean over the signals, computed before this type is asked
    /// anything, and the dimensions drawer is built from the same signals — so
    /// the pro loses a sentence and never the truth about the frame.
    @Test func backingOffDoesNotMoveReadinessOrTheDimensionsDrawer() {
        let coaches: [ShotCoach] = [ColorCoach(), BackgroundCoach()]
        let ctx = FrameContext(
            avgLuma: 0.5, faceBounds: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.4),
            faceLuma: 0.5, backgroundLuma: 0.5, sharpness: 1,
            backgroundClutter: 1, subjectFill: 0.4, pose: nil, deviceTilt: 0,
            color: ColorSignal(mixed: 1, greenTint: 0, warmth: 0, backgroundScoped: true),
            expectations: nil)

        var arbiter = CoachTipArbiter()
        let first = CoachAggregate.evaluate(coaches, ctx, arbiter: &arbiter, now: 0)
        #expect(first.nudge?.moment == .colorMixed)

        let step = 1.0 / CoachTuning.analysisFPS
        var now = step
        var latest = first
        while now <= silence + 1 {
            latest = CoachAggregate.evaluate(coaches, ctx, arbiter: &arbiter, now: now)
            now += step
        }
        #expect(latest.nudge?.moment == .backgroundBusy, "the coach moved on")
        #expect(latest.readiness == first.readiness, "the ring must still count the deficit")
        #expect(latest.statuses.map(\.score) == first.statuses.map(\.score))
        #expect(latest.statuses.map(\.message) == first.statuses.map(\.message),
                "the drawer is the surface the pro opened to ask why it won't go green")
    }

    /// The ladder holds the last correction on screen while it waits out the
    /// stability window. It must hold the WORDING it was last shown in too —
    /// otherwise a rung that had backed off to its plainest form grows its
    /// diagnosis clause back for 1.5s, and the coach appears to get wordier at
    /// the exact moment the pro finally fixed it.
    @Test func theLastCorrectionIsHeldInTheWordingItWasLastShownIn() {
        var arbiter = CoachTipArbiter()
        let broken: [(CoachCategory, CoachSignal)] = [
            signal(.color, score: 0.45, moment: .colorMixed),
            signal(.background, score: 0.5, moment: .backgroundBusy),
        ]
        let plainer = run(&arbiter, broken, from: 0, seconds: silence - 2)
        #expect(plainer?.simplified == true)

        // Colour reads good, but not for long enough to be believed yet.
        let colourFixed = [signal(.background, score: 0.5, moment: .backgroundBusy)]
        let waiting = arbiter.select(from: colourFixed, now: silence - 1)
        #expect(waiting.nudge?.moment == .colorMixed, "still holding the last correction")
        #expect(waiting.simplified == true, "…and still in the words it was last said in")
        #expect(waiting.advanced == nil)
    }

    /// The memory-free overload is asked exactly once with a fresh arbiter, so
    /// no rung can ever have stalled: the offline bench and every pinned
    /// `CoachReadinessTests` assertion keep reading canonical behaviour.
    @Test func theMemoryFreeOverloadNeverBacksOffAnything() {
        let ctx = FrameContext(
            avgLuma: 0.5, faceBounds: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.4),
            faceLuma: 0.5, backgroundLuma: 0.5, sharpness: 1,
            backgroundClutter: 1, subjectFill: 0.4, pose: nil, deviceTilt: 0,
            color: ColorSignal(mixed: 1, greenTint: 0, warmth: 0, backgroundScoped: true),
            expectations: nil)
        let verdict = CoachAggregate.evaluate([ColorCoach(), BackgroundCoach()], ctx)
        #expect(verdict.nudge?.moment == .colorMixed)
        #expect(verdict.simplified == false)
    }
}
