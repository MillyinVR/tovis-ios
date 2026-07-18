import Testing
@testable import TovisKit

// The optimistic follow state machine shared by the activity follow-back pill,
// the public creator profile button, and the Me › Following suggestions rail.
//
// These transitions were hand-copied per view before this, and the copies had
// already drifted — `rollbackRestoresZeroCountExactly` pins a bug one of them
// shipped. Living in TovisKit is what puts them under `swift test`, which is the
// only gate this repo has.

struct FollowToggleTests {

    // MARK: - The optimistic flip

    @Test func beginFlipsOptimisticallyAndReturnsDesiredState() {
        var toggle = FollowToggle(following: false, followerCount: 7)

        let next = toggle.begin()

        // begin() hands back the desired state so a desired-state route (the pro
        // side, queue item 13) has something to send.
        #expect(next == true)
        #expect(toggle.following == true)
        #expect(toggle.followerCount == 8)  // the visible count moves immediately
        #expect(toggle.isWorking == true)
    }

    @Test func beginFromFollowingFlipsDown() {
        var toggle = FollowToggle(following: true, followerCount: 3)

        #expect(toggle.begin() == false)
        #expect(toggle.following == false)
        #expect(toggle.followerCount == 2)
    }

    // MARK: - Re-entrancy (the blind-toggle hazard)

    @Test func secondBeginWhileInFlightIsRefused() {
        var toggle = FollowToggle(following: false, followerCount: 0)

        #expect(toggle.begin() != nil)
        let second = toggle.begin()

        // A double tap must NOT fire a second request: POST /client/follow/{handle}
        // carries no desired state, so a second call would UNDO the first.
        #expect(second == nil)
        #expect(toggle.following == true)  // and the refused tap must not flip it back
        #expect(toggle.followerCount == 1)
    }

    // MARK: - Reconciling with the server

    @Test func finishTakesServerTruthEvenWhenItContradictsTheFlip() {
        var toggle = FollowToggle(following: false, followerCount: 10)
        _ = toggle.begin()  // optimistically following, count 11

        // The viewer's state was stale: the blind toggle actually turned it OFF.
        toggle.finish(FollowState(following: false, followerCount: 9))

        #expect(toggle.following == false)  // server truth wins outright
        #expect(toggle.followerCount == 9)
        #expect(toggle.isWorking == false)
    }

    @Test func finishClampsNegativeServerCount() {
        var toggle = FollowToggle(following: true, followerCount: 1)
        _ = toggle.begin()

        toggle.finish(FollowState(following: false, followerCount: -4))

        #expect(toggle.followerCount == 0)
    }

    @Test func finishAllowsAnotherToggleAfterwards() {
        var toggle = FollowToggle()
        _ = toggle.begin()
        toggle.finish(FollowState(following: true, followerCount: 1))

        #expect(toggle.begin() != nil)  // usable again once the call lands
    }

    // MARK: - Rollback

    @Test func failRestoresPreFlipValues() {
        var toggle = FollowToggle(following: false, followerCount: 5)
        _ = toggle.begin()

        toggle.fail()

        #expect(toggle.following == false)
        #expect(toggle.followerCount == 5)
        #expect(toggle.isWorking == false)
    }

    /// The drift the hand-rolled copy actually shipped. `PublicClientProfileContent`
    /// rolled back by re-deriving from the *already-nudged* value
    /// (`max(0, followerCount + (next ? -1 : 1))`). When an unfollow was attempted
    /// at a count of 0, the optimistic nudge clamped to 0, and the rollback then
    /// added 1 — leaving a follower count of 1 after a FAILED unfollow, out of thin
    /// air. Restoring from a snapshot can't do that.
    @Test func rollbackRestoresZeroCountExactly() {
        var toggle = FollowToggle(following: true, followerCount: 0)

        #expect(toggle.begin() == false)
        #expect(toggle.followerCount == 0)  // clamped, not negative

        toggle.fail()

        #expect(toggle.followerCount == 0)  // must not invent a follower
        #expect(toggle.following == true)
    }

    @Test func failWithNoCallInFlightOnlyClearsBusy() {
        var toggle = FollowToggle(following: true, followerCount: 4)

        toggle.fail()

        #expect(toggle.following == true)  // untouched when nothing was in flight
        #expect(toggle.followerCount == 4)
        #expect(toggle.isWorking == false)
    }

    @Test func failThenRetrySucceeds() {
        var toggle = FollowToggle(following: false, followerCount: 2)
        _ = toggle.begin()
        toggle.fail()

        #expect(toggle.begin() == true)  // a failed call leaves the control retryable
        toggle.finish(FollowState(following: true, followerCount: 3))
        #expect(toggle.following == true)
        #expect(toggle.followerCount == 3)
    }

    @Test func initClampsNegativeSeedCount() {
        let toggle = FollowToggle(following: false, followerCount: -2)
        #expect(toggle.followerCount == 0)
    }
}
