// Where a tapped notification row goes.
//
// Both notification centers render EVERY row as a tappable control, but only a
// row carrying a `bookingId` ever navigated — every other row silently marked
// itself read and stayed put. The server already says where each row belongs in
// its `href` (`/looks/{id}`, `/client/offers`, `/client/referrals`,
// `/messages/thread/{id}`, `/pro/reviews`, …); the feed just never read it.
//
// The app already knows how to route an internal path: `PushDeepLink` is the
// parser a tapped push goes through, and both shells already observe
// `session.pushDeepLink` and present the result. These resolve the row's href
// through THAT parser rather than adding another one — the notification feed and
// the push payloads carry the same internal paths, so a second parser here would
// drift from the one push taps use.
//
// ⚠️ Deliberately NOT `ClientActivityItem.destination`: that parser covers the
// ACTIVITY feed's paths (`/looks/{id}`, `/u/{handle}`) and would return nil for
// `/client/offers`, `/client/referrals`, `/client/activity` and
// `/messages/thread/{id}` — most of what this feed actually emits. `/u/{handle}`
// is never emitted here at all (a new follower is `/client/activity`).
//
// A path with no native surface stays `nil`, and the caller leaves the tap as a
// mark-read. That matters: these screens are sheets, so routing is "dismiss, then
// present". Dismissing on an unroutable path would close the notification center
// and land nowhere — strictly worse than the dead tap it replaced.
import TovisKit

extension ClientNotification {
    /// The native destination this row opens, or `nil` when its path has none.
    var deepLink: PushDeepLink? { PushDeepLink(href: href) }
}

extension ProNotification {
    /// The native destination this row opens, or `nil` when its path has none.
    var deepLink: PushDeepLink? { PushDeepLink(href: href) }
}
