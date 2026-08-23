// The Session Reel's admission policy, driven a frame at a time.
//
// `CoachReadinessTests` pins what a frame SCORES; this pins what the reel does
// with the score. The two meet in
// `CoachReadinessTests.theSameFrameIsBankedOnceTheHoldIsSteady`, which runs a
// really-scored salon frame through the real gate so neither half can drift
// while staying green on its own.
//
// The thresholds are read live off `CoachTuning` rather than hardcoded, so a
// device pass that retunes one retunes these with it — what is pinned here is
// the BEHAVIOUR. The readiness VALUES are deliberate literals (the measured
// salon frame and its neighbours): if a retune moves the green ring past them
// this should break loudly rather than quietly re-testing a different band.
//
// Frame times step at the analyzer's real cadence, and 1/6 of a second is not
// representable in binary — so "just after the spacing floor" is written as the
// next analyzed FRAME after it, never as the floor itself. That is also what
// the camera actually does: nothing is decided between frames.
import Testing
@testable import Tovis

@Suite struct CoachHarvestGateTests {
    /// The ordinary salon frame, measured: mixed light + a busy backdrop + a few
    /// degrees of hand tilt scores 0.826 (docs/camera-tuning-bench.md, and
    /// `CoachReadinessTests.anOrdinarySalonFrameLandsBetweenTheRingAndThePeakGate`
    /// re-derives it from the coaches). Green, and never a peak.
    private let ordinarySalonFrame = 0.826
    /// Comfortably past the peak gate — the frame the reel always took.
    private let excellentFrame = 0.92
    /// Amber: the ring is not green, so the pro is being corrected, not shot.
    private let amberFrame = 0.70

    /// One analyzed frame's worth of time.
    private var step: Double { 1 / CoachTuning.analysisFPS }

    /// Drive a stream of `(now, readiness)` through the gate, banking whatever
    /// it offers — the tray always has room here. Returns what the reel ended
    /// up with.
    private func run(_ stream: [(now: Double, readiness: Double)],
                     gate: inout CoachHarvestGate) -> [(now: Double, readiness: Double,
                                                        why: CoachHarvestGate.Decision)] {
        var banked: [(now: Double, readiness: Double, why: CoachHarvestGate.Decision)] = []
        for frame in stream {
            let decision = gate.shouldHarvest(readiness: frame.readiness, now: frame.now)
            guard decision.banks else { continue }
            gate.didHarvest(readiness: frame.readiness, at: frame.now)
            banked.append((frame.now, frame.readiness, decision))
        }
        return banked
    }

    /// A steady hold at the analyzer's real cadence, starting at `from`.
    private func hold(_ readiness: Double, seconds: Double,
                      from: Double = 0) -> [(now: Double, readiness: Double)] {
        (0..<Int((seconds / step).rounded())).map { (from + Double($0) * step, readiness) }
    }

    /// The first analyzed frame at or after `t`, which is when the camera can
    /// act on anything — asserted as a window one frame wide rather than as an
    /// instant the analyzer never samples.
    private func banked(_ shot: (now: Double, readiness: Double, why: CoachHarvestGate.Decision),
                        atFirstFrameAfter t: Double) -> Bool {
        shot.now >= t && shot.now < t + step
    }

    // MARK: - The regression this change exists for

    /// THE REGRESSION (plan item 2). Ten seconds of ordinary salon shooting at
    /// the analyzer's real cadence, peaking at 0.826 and never once reaching the
    /// peak gate. Under the old peak-only rule this session ended with an empty
    /// tray — and the pro had watched a green ring the whole time.
    @Test func aSessionThatPeaksAt0Point82StillFillsTheReel() {
        let stream = hold(ordinarySalonFrame, seconds: 10)
        // The red-proof, stated rather than remembered: the peak gate alone
        // takes NOTHING out of this session.
        #expect(!stream.contains { $0.readiness >= CoachTuning.harvestThreshold })
        #expect(stream.allSatisfy { $0.readiness >= CoachTuning.readyThreshold })

        var gate = CoachHarvestGate()
        let shots = run(stream, gate: &gate)

        #expect(shots.count >= 1)
        #expect(shots.allSatisfy { $0.why == .steadyHold })
        // …and not by flooding: one unbroken pose is worth one keeper, however
        // long the pro holds it. Ten green seconds could otherwise have spent
        // four of the tray's 24 slots on the same framing.
        #expect(shots.count == 1)
        // Banked as soon as the hold was steady, not at the end of the session.
        #expect(banked(shots[0], atFirstFrameAfter: CoachTuning.autoCaptureHoldSeconds))
    }

    // MARK: - What the backstop requires

    /// A hold has to actually BE steady first. Green alone is not enough — the
    /// same window the guided shutter waits out, for the same reason: a frame
    /// grabbed mid-movement is a blurred frame with a good score.
    @Test func aHoldBanksNothingUntilItHasHeldLongEnoughToEarnAShutter() {
        var gate = CoachHarvestGate()
        let held = CoachTuning.autoCaptureHoldSeconds
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame, now: 0) == .skip)
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame, now: held - 0.01) == .skip)
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame, now: held) == .steadyHold)
    }

    /// The floor under the whole thing: below the green ring nothing is ever
    /// banked, however long the pro holds it. The reel is not a backstop
    /// against a bad frame — it is a backstop against a GOOD session going
    /// uncollected.
    @Test func anAmberFrameIsNeverBankedHoweverLongItIsHeld() {
        var gate = CoachHarvestGate()
        #expect(amberFrame < CoachTuning.readyThreshold)
        #expect(run(hold(amberFrame, seconds: 30), gate: &gate).isEmpty)
    }

    /// Breaking green ends the hold, and the next one owes its own frame — which
    /// is what makes the reel collect one keeper per POSE rather than one per
    /// session. Moving to a new angle drops readiness (motion softens the
    /// frame); settling again is a new hold, even at the very same score.
    @Test func breakingGreenStartsAHoldThatOwesItsOwnFrame() {
        var gate = CoachHarvestGate()
        var stream = hold(ordinarySalonFrame, seconds: 3)
        // The pro moves to the next angle — readiness falls out of the ring…
        stream += hold(amberFrame, seconds: 1, from: 3)
        // …and settles into a second pose, no better than the first.
        stream += hold(ordinarySalonFrame, seconds: 5, from: 4)

        let shots = run(stream, gate: &gate)
        #expect(shots.count == 2)
        #expect(shots.allSatisfy { $0.why == .steadyHold })
        #expect(banked(shots[0], atFirstFrameAfter: CoachTuning.autoCaptureHoldSeconds))
        // The second pose banks as soon as IT is steady — the spacing floor had
        // long since elapsed, so the hold window is what it waited on.
        #expect(banked(shots[1], atFirstFrameAfter: 4 + CoachTuning.autoCaptureHoldSeconds))
    }

    /// Within one hold, the reel only takes another frame if the hold actually
    /// got BETTER — "banks its best frame", served forward, since there is no
    /// going back for the good frame from two seconds ago.
    @Test func aHoldBanksAgainOnlyWhenItImprovesOnWhatTheReelAlreadyTook() {
        var gate = CoachHarvestGate()
        let held = CoachTuning.autoCaptureHoldSeconds
        let after = held + CoachTuning.minHarvestInterval + step

        // The hold has to open before it can mature — it is made of the frames
        // in between, which is why the gate sees every one of them.
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame, now: 0) == .skip)
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame, now: held) == .steadyHold)
        gate.didHarvest(readiness: ordinarySalonFrame, at: held)

        // Worse than what the reel already holds, spacing elapsed: still no.
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame - 0.01, now: after) == .skip)
        // Identical is not an improvement either — a static pose is not news.
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame, now: after) == .skip)
        // Genuinely better: taken.
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame + 0.01, now: after) == .steadyHold)
    }

    // MARK: - What the backstop must not disturb

    /// The peak path, unchanged: an excellent frame banks the instant it
    /// appears, with no hold behind it at all. A moment that good is worth
    /// keeping even when the pro never settles into it.
    @Test func anExcellentFrameStillBanksImmediatelyWithNoHoldBehindIt() {
        var gate = CoachHarvestGate()
        #expect(gate.shouldHarvest(readiness: excellentFrame, now: 0) == .peak)
    }

    /// …and keeps banking at the spacing floor for as long as it stays
    /// excellent, exactly as it did before the backstop existed. The
    /// improvement rule governs the BACKSTOP; it must not quietly throttle the
    /// path that was already there.
    @Test func anExcellentHoldStillBanksEverySpacingIntervalAsItAlwaysDid() {
        var gate = CoachHarvestGate()
        let shots = run(hold(excellentFrame, seconds: 10), gate: &gate)

        #expect(shots.allSatisfy { $0.why == .peak })
        #expect(shots.first?.now == 0)   // no hold to wait out
        // 10 seconds at a 2.5s floor, taken at the first frame past each floor.
        #expect(shots.count == 4)
        for (earlier, later) in zip(shots, shots.dropFirst()) {
            let gap = later.now - earlier.now
            #expect(gap >= CoachTuning.minHarvestInterval)
            #expect(gap < CoachTuning.minHarvestInterval + step)
        }
    }

    /// The spacing floor governs both ways in — a hold that becomes excellent
    /// cannot jump the queue on a frame the backstop just banked.
    @Test func theSpacingFloorHoldsAcrossBothWaysIn() {
        var gate = CoachHarvestGate()
        let held = CoachTuning.autoCaptureHoldSeconds
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame, now: 0) == .skip)
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame, now: held) == .steadyHold)
        gate.didHarvest(readiness: ordinarySalonFrame, at: held)

        #expect(gate.shouldHarvest(readiness: excellentFrame, now: held + 0.5) == .skip)
        #expect(gate.shouldHarvest(
            readiness: excellentFrame,
            now: held + CoachTuning.minHarvestInterval + step) == .peak)
    }

    /// A peak counts as the hold's best, so the backstop cannot follow a great
    /// frame with a lesser copy of the same pose. Without this the reel would
    /// take 0.92 and then 0.826 out of one unbroken hold and call both keepers.
    @Test func aPeakBankRaisesTheHoldsBestSoTheBackstopCannotAddALesserCopy() {
        var gate = CoachHarvestGate()
        #expect(gate.shouldHarvest(readiness: excellentFrame, now: 0) == .peak)
        gate.didHarvest(readiness: excellentFrame, at: 0)

        let after = CoachTuning.minHarvestInterval + step
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame, now: after) == .skip)
    }

    /// The tray cap (`maxHarvest`, enforced by `CoachAnalyzer`'s slot
    /// reservation) still owns the ceiling: an offer the tray had no room for
    /// must leave the gate exactly as it found it, so the frame is offered
    /// again rather than silently spending the hold's one bank on a shot that
    /// was never encoded. This is why `didHarvest` is a separate call and not
    /// something `shouldHarvest` does to itself.
    @Test func anOfferTheTrayRefusesLeavesTheGateUntouched() {
        var gate = CoachHarvestGate()
        let held = CoachTuning.autoCaptureHoldSeconds
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame, now: 0) == .skip)

        // Offered, refused (no `didHarvest`) — three frames running.
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame, now: held) == .steadyHold)
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame, now: held + step) == .steadyHold)
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame, now: held + 2 * step) == .steadyHold)

        // A slot frees up and the next offer is taken — and only THEN does the
        // gate stop offering.
        gate.didHarvest(readiness: ordinarySalonFrame, at: held + 2 * step)
        #expect(gate.shouldHarvest(readiness: ordinarySalonFrame, now: held + 3 * step) == .skip)
    }
}
