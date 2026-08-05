// Auto-capture's arming rule, and specifically the silent stall it used to have
// after a QC-rejected burst.
//
// The failure was invisible in the UI and self-healing on the success path,
// which is why it survived: the lane said "holding for another try" while
// auto-capture was, in fact, dead. See `GuidedCaptureArm` for the full trace.
import Testing
@testable import Tovis

@Suite struct GuidedCaptureArmTests {
    @Test func itFiresOnceThenWaitsForTheNextSetup() {
        var arm = GuidedCaptureArm()
        #expect(arm.shouldFire(steady: true))

        arm.didFire()
        #expect(!arm.shouldFire(steady: true))   // one shot per setup, not continuously

        arm.captureFinished(kept: true)
        #expect(!arm.shouldFire(steady: true))   // still disarmed — the shot was filed

        arm.readinessChanged(ready: false)       // the pro moves to the next angle
        #expect(arm.shouldFire(steady: true))
    }

    /// THE REGRESSION. A burst where nothing survived QC, with the client
    /// holding perfectly still — so readiness never leaves the green ring and
    /// the old "re-arm when readiness drops" rule never runs.
    @Test func aRejectedBurstRearmsWithoutTheShotLeavingTheGreenRing() {
        var arm = GuidedCaptureArm()
        arm.didFire()
        arm.captureFinished(kept: false)   // three frames, none passed QC

        // Note what is NOT called here: `readinessChanged`. The frame is still
        // ready. Under the old rule auto-capture stayed dead from this point on.
        #expect(arm.shouldFire(steady: true))
    }

    @Test func aRejectedBurstStillWaitsForASteadyFrame() {
        var arm = GuidedCaptureArm()
        arm.didFire()
        arm.captureFinished(kept: false)
        // Re-armed, but the retry is still gated on the hold re-establishing —
        // it doesn't machine-gun the shutter the instant QC says no.
        #expect(!arm.shouldFire(steady: false))
    }

    @Test func droppingOutOfReadyAlwaysRearms() {
        var arm = GuidedCaptureArm()
        arm.didFire()
        #expect(!arm.shouldFire(steady: true))
        arm.readinessChanged(ready: false)
        #expect(arm.shouldFire(steady: true))
        // Coming back to ready must not disarm something already armed.
        arm.readinessChanged(ready: true)
        #expect(arm.shouldFire(steady: true))
    }
}
