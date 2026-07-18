import Foundation

/// The optimistic state machine behind every **handle-addressed** (client→client)
/// follow control: the compact pill in the activity feed, the wide button on a
/// public creator profile, and the "Creators to follow" rail on Me › Following.
///
/// Those controls look nothing alike — different sizes, and only one of them has
/// a follower count to show — so the *chrome* stays in each view. What they had
/// hand-copied three times, and what lives here instead, is the decision-making:
///
/// 1. **A re-entrancy guard.** `POST /api/v1/client/follow/{handle}` is a blind
///    TOGGLE — it carries no desired state, so it flips whatever the server
///    currently holds. A second tap while the first is in flight therefore
///    *undoes* the follow rather than being a harmless duplicate. `begin()`
///    returns `nil` in that window and the caller must not fire.
/// 2. **The optimistic flip** (plus the follower-count nudge) so the tap feels
///    instant.
/// 3. **Reconciling against the server's authoritative answer** rather than
///    assuming the local flip won — the same reason the route returns
///    `{ following, followerCount }` at all.
/// 4. **Rolling back to the pre-flip values** when the call throws, from a
///    snapshot taken here rather than by re-deriving the old value at the call
///    site (which is where a hand-rolled copy drifts).
///
/// Deliberately UI-free and a value type, matching TovisKit's contract: views
/// hold it in `@State`, and `swift test` — the only gate this repo has — can
/// drive every transition without a running app.
///
/// The pro-side follow (`LooksService.setFollow(professionalId:following:)`) is
/// **not** modelled here yet: it is keyed by id, not handle, and its route takes
/// an explicit desired state (POST/DELETE), so "reconcile because we don't know
/// what we flipped" doesn't apply the same way. `perform`-style callers can still
/// adopt this later — `begin()` hands back the desired next state precisely so a
/// desired-state route has something to send. Merging those three sites is queue
/// item 13.
public struct FollowToggle: Equatable, Sendable {
    /// Whether the viewer currently follows the target.
    public private(set) var following: Bool
    /// The target's follower count. Controls without one (the activity pill, the
    /// suggestions rail) simply never read it; it still tracks correctly so a
    /// view that later grows a count doesn't need new logic.
    public private(set) var followerCount: Int
    /// True while a request is in flight. Bind this to `.disabled(…)`.
    public private(set) var isWorking: Bool

    /// Pre-flip values, held only for the duration of a call so `fail()` can
    /// restore them exactly.
    private var restorePoint: RestorePoint?

    private struct RestorePoint: Equatable, Sendable {
        let following: Bool
        let followerCount: Int
    }

    public init(following: Bool = false, followerCount: Int = 0) {
        self.following = following
        self.followerCount = max(0, followerCount)
        self.isWorking = false
        self.restorePoint = nil
    }

    /// Optimistically flips the control and marks it busy.
    ///
    /// - Returns: the desired next follow state, or `nil` when a call is already
    ///   in flight — in which case the caller **must not** send a request (see
    ///   the blind-toggle note above).
    public mutating func begin() -> Bool? {
        guard !isWorking else { return nil }

        restorePoint = RestorePoint(following: following, followerCount: followerCount)

        let next = !following
        following = next
        followerCount = max(0, followerCount + (next ? 1 : -1))
        isWorking = true
        return next
    }

    /// Reconciles with the server's authoritative response and clears the busy
    /// flag. Server truth wins outright — including when it disagrees with the
    /// optimistic flip, which is exactly what a blind toggle can produce if the
    /// viewer's state was stale.
    public mutating func finish(_ state: FollowState) {
        following = state.following
        followerCount = max(0, state.followerCount)
        isWorking = false
        restorePoint = nil
    }

    /// Restores the pre-flip values after a failed call and clears the busy flag.
    /// A no-op on the values if no call was in flight.
    public mutating func fail() {
        if let restorePoint {
            following = restorePoint.following
            followerCount = restorePoint.followerCount
        }
        isWorking = false
        restorePoint = nil
    }
}
