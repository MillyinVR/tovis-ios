import Testing
@testable import TovisKit

// The optimistic follow state machine shared by all six follow controls — the
// handle-addressed three (activity follow-back pill, public creator profile
// button, Me › Following suggestions rail) and the id-addressed three (looks feed
// pill, look detail button, pro profile hero pill).
//
// These transitions were hand-copied per view before this, and every copy had
// drifted somewhere different — the tests named for a surface each pin a bug that
// surface actually shipped. Living in TovisKit is what puts them under
// `swift test`, which is the only gate this repo has.

struct FollowToggleTests {

    // MARK: - The optimistic flip

    @Test func beginFlipsOptimisticallyAndReturnsDesiredState() {
        var toggle = FollowToggle(following: false, followerCount: 7)

        let next = toggle.begin()

        // begin() hands back the state it optimistically moved to. Both routes are
        // blind toggles, so no caller has to *send* this — it is there for callers
        // that want to branch on it.
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

    // MARK: - The id-addressed (client→pro) family
    //
    // Same state machine, and — contrary to what the queue card assumed —
    // the same *contract*: POST /pros/{id}/follow runs `toggleProFollow`, so it
    // blind-toggles exactly like the handle route. The three copies that backed
    // it each got a different part of this wrong.

    /// `LookDetailView` nudged with a bare `count + (next ? 1 : -1)` and no clamp.
    /// An unfollow against a stale count of 0 therefore produced **-1**. (It never
    /// rendered its count, so this was latent there — but the same unclamped shape
    /// on a surface that *does* render one is a visible "-1 followers".)
    @Test func proUnfollowAtZeroNeverGoesNegative() {
        var toggle = FollowToggle(following: true, followerCount: 0)

        #expect(toggle.begin() == false)
        #expect(toggle.followerCount == 0)  // not -1
    }

    /// Rolling back returns the seed exactly, which is what lets a call site that
    /// seeds from a payload decide the toggle is back to its default.
    ///
    /// ⚠️ Scope, stated honestly: re-deriving (`!next`) and snapshot-restoring
    /// produce the *same value* everywhere except the clamp edge — which is why
    /// this test passes against both, and why `rollbackRestoresZeroCountExactly`
    /// is the one that actually discriminates. `LooksView`'s real defect was not
    /// the value at all but that it *wrote a dictionary entry* for a follow that
    /// never happened, shadowing `viewerFollows` across `reloadKeepingPlace()`.
    /// That lives in the view's dictionary, which `swift test` cannot reach —
    /// it is fixed by restoring the entry (including absence) at the call site,
    /// and verified on the simulator, not here.
    @Test func proRollbackRestoresTheSeedExactly() {
        // Seeded from a feed payload that says "not following, 42 followers".
        var toggle = FollowToggle(following: false, followerCount: 42)

        #expect(toggle.begin() == true)
        #expect(toggle.followerCount == 43)  // optimistic

        toggle.fail()

        #expect(toggle.following == false)
        #expect(toggle.followerCount == 42)  // exactly the seed, not a re-derivation
        #expect(toggle.isWorking == false)
    }

    /// The round trip end to end: flip optimistically, POST, then settle on the
    /// server's echo rather than on the optimistic guess.
    @Test func proToggleRoundTrip() {
        var toggle = FollowToggle(following: false, followerCount: 11)

        guard let optimistic = toggle.begin() else {
            Issue.record("begin() refused on an idle toggle")
            return
        }
        #expect(optimistic == true)

        toggle.finish(FollowState(following: true, followerCount: 12))

        #expect(toggle.following == true)
        #expect(toggle.followerCount == 12)
        #expect(toggle.isWorking == false)
    }

    /// Only `ProProfileView` had a re-entrancy guard — and because this route
    /// blind-toggles too, its absence on the other two was a correctness bug, not
    /// just a redundant request: the second call would have undone the first.
    @Test func proSecondTapDoesNotFireASecondRequest() {
        var toggle = FollowToggle(following: false, followerCount: 3)

        #expect(toggle.begin() == true)
        #expect(toggle.begin() == nil)      // no second request
        #expect(toggle.following == true)   // and the refused tap changes nothing
        #expect(toggle.followerCount == 4)
    }
}
