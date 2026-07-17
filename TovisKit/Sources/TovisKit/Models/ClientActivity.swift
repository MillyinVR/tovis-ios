import Foundation

// Wire models for the client "Activity" feed — GET /api/v1/client/activity.
// Mirrors `ClientActivityFeedDTO` (lib/dto/clientActivity.ts) + the route in
// app/api/v1/client/activity/route.ts, which serializes the SAME loader the web
// /client/activity page renders, so the two surfaces cannot drift.
//
// `who`/`action`/`highlight` are composed SERVER-side, so both clients render
// identical copy and neither can drift it. Only the relative time is formatted
// natively (it goes stale, so it cannot be baked into the response) — see
// `ActivityTimeAgo`, which ports web's `formatRelativeTimeAgo` buckets.

/// Envelope for `GET /api/v1/client/activity` → `{ ok, activity }`.
struct ClientActivityResponse: Decodable, Sendable {
    let activity: ClientActivityFeed
}

public struct ClientActivityFeed: Decodable, Sendable {
    public let items: [ClientActivityItem]
    /// Unread activity events — the same count that badges the Me header bell.
    public let unreadCount: Int
    /// The allowlist "Mark all read" hands back to POST /client/notifications/read.
    /// Server-owned on purpose: the client must not hard-code the event set.
    public let markReadEventKeys: [String]

    public init(items: [ClientActivityItem], unreadCount: Int, markReadEventKeys: [String]) {
        self.items = items
        self.unreadCount = unreadCount
        self.markReadEventKeys = markReadEventKeys
    }
}

/// Which glyph a row renders.
///
/// ⚠️ `remix` and `featured` are in the published union but **no backend event
/// produces them today** (see `ACTIVITY_FEED_EVENT_KEYS` — the server's own
/// comment records them as planned). They are modeled so that shipping those
/// events later does not require an app release, not because anything renders
/// them now. `unknown` keeps a future kind from failing the whole row's decode.
public enum ActivityIconKind: String, Decodable, Sendable, CaseIterable {
    case follow
    case comment
    case like
    case save
    case newLook = "new-look"
    case remix
    case featured
    case milestone
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ActivityIconKind(rawValue: raw) ?? .unknown
    }
}

/// Present for a follow row whose follower is publicly addressable. A private or
/// handle-less follower arrives as `nil` (the server renders them "Someone" with
/// no href), so there is nothing to follow back.
public struct ActivityFollowBack: Decodable, Sendable, Equatable {
    public let handle: String
    public let alreadyFollowing: Bool

    public init(handle: String, alreadyFollowing: Bool) {
        self.handle = handle
        self.alreadyFollowing = alreadyFollowing
    }
}

public struct ClientActivityItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let iconKind: ActivityIconKind
    /// Pre-composed actor label ("@ava" / "Someone" / "4 people" / "Your look").
    public let who: String
    /// Pre-composed predicate ("started following you").
    public let action: String
    /// Optional quoted snippet (a comment body / caption), already quoted.
    public let highlight: String?
    /// ISO instant; the client formats it relative via `ActivityTimeAgo`.
    public let timestamp: String
    public let unread: Bool
    /// Where the row (and any "View" affordance) leads, when applicable.
    public let href: String?
    public let followBack: ActivityFollowBack?

    public init(
        id: String,
        iconKind: ActivityIconKind,
        who: String,
        action: String,
        highlight: String? = nil,
        timestamp: String,
        unread: Bool,
        href: String? = nil,
        followBack: ActivityFollowBack? = nil
    ) {
        self.id = id
        self.iconKind = iconKind
        self.who = who
        self.action = action
        self.highlight = highlight
        self.timestamp = timestamp
        self.unread = unread
        self.href = href
        self.followBack = followBack
    }

    /// A row offers follow-back only when the follower is addressable AND the
    /// viewer isn't already following them — mirroring web's `ActivityRow`,
    /// which falls through to the "View" link otherwise.
    public var offersFollowBack: Bool {
        guard let followBack else { return false }
        return !followBack.alreadyFollowing
    }

    /// Where the row's "View" affordance leads, resolved from the server's `href`.
    ///
    /// `nil` when there is no href OR when the path is one native cannot route —
    /// the view then renders no affordance at all rather than a tap that goes
    /// nowhere. (Web can always fall back to rendering the page itself; a native
    /// "View" that does nothing is strictly worse than no button.)
    public var destination: ActivityDestination? {
        guard let href, let components = URLComponents(string: href) else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)

        switch parts.first {
        // `/looks/{id}` — and ONLY that. `/looks/tags/{slug}` is a tag chip, not a
        // look: parsing it loosely would resolve id == "tags" and open a detail for
        // a look that does not exist. (The same latent bug shipped in PushDeepLink.)
        case "looks" where parts.count == 2:
            return .look(id: parts[1])
        // `/u/{handle}` — the public client profile a follow row points at.
        case "u" where parts.count == 2:
            return .publicClient(handle: parts[1])
        default:
            return nil
        }
    }
}

// MARK: - Optimistic row patches
//
// The feed is a value type, so a screen cannot mutate a row in place the way
// web's `setRows(...)` does. These return the patched copy, and live here rather
// than in the view so `swift test` can reach them.
extension ClientActivityItem {
    /// The row as "Mark all read" leaves it. Only `unread` changes — a read row
    /// keeps its follow-back affordance and its link.
    public func markingRead() -> ClientActivityItem {
        ClientActivityItem(
            id: id, iconKind: iconKind, who: who, action: action, highlight: highlight,
            timestamp: timestamp, unread: false, href: href, followBack: followBack
        )
    }

}

/// A native screen an activity row can open. Kept deliberately narrow: only the
/// paths the activity feed actually emits (`/looks/{id}` from engagement rows,
/// `/u/{handle}` from a public follower).
public enum ActivityDestination: Equatable, Sendable {
    case look(id: String)
    case publicClient(handle: String)
}

/// Native port of web's `formatRelativeTimeAgo` (lib/time/relativeTime.ts) — the
/// wording the activity feed uses ("just now" / "5m ago" / "4w ago" / "Mar 5").
///
/// Deliberately NOT `RelativeDateTimeFormatter`: it renders "now" where web says
/// "just now" and never falls back to a date, so the same row would read
/// differently on the two platforms.
///
/// This is NOT a duplicate of the app's `Wire.relativeAgo` — web deliberately
/// ships two relative formatters off one bucketing core (`formatRelativeTimeCompact`
/// for comment-style "5m", `formatRelativeTimeAgo` for the activity feed), and
/// `Wire.relativeAgo` is the compact one (no "ago" suffix, no week bucket). Mirroring
/// both is parity; collapsing them would change copy on the surfaces that use the
/// compact form.
public enum ActivityTimeAgo {
    /// Web's `bucketRelativeTime(input, weekCap: 5)` plus the "ago" wording.
    /// Unparseable input → "" (web returns '' too). Uses TovisKit's shared ISO
    /// reader rather than a private parser, as `ClientOffers` does.
    public static func label(
        for timestamp: String,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        guard let then = ProCalendarGrid.parseISO(timestamp) else { return "" }
        return label(for: then, now: now, timeZone: timeZone)
    }

    /// A future timestamp clamps to zero elapsed — web does `Math.max(0, …)`, so
    /// a clock skew reads "just now" rather than a negative age.
    public static func label(
        for then: Date,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let elapsed = max(0, now.timeIntervalSince(then))

        let minutes = Int(elapsed / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }

        let days = hours / 24
        if days < 7 { return "\(days)d ago" }

        let weeks = days / 7
        if weeks < 5 { return "\(weeks)w ago" }

        // Past the 5-week cap web falls back to a short month/day date. Pinned to
        // en_US like the app's sibling `Wire.monthDay`/`Wire.relativeAgo`.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: then)
    }
}
