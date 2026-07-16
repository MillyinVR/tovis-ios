import Foundation

/// "Why you're showing up" — the pro-side transparency read (web §6.5 parity).
/// Decoded from `GET /api/v1/pro/visibility` → `{ ok, visibility }`.
///
/// The server owns every decision here: which levers exist, their status, and
/// the copy. This model is a faithful carrier — it deliberately holds no
/// thresholds and no ranking knowledge of its own, so the native screen can
/// never disagree with the web dashboard about why a pro is or isn't surfacing.
public struct ProVisibilityHealth: Decodable, Sendable {
    /// Worst lever status — drives the header tone.
    public let status: ProVisibilityStatus
    /// False = the pro is filtered out of discovery entirely; levers are moot.
    public let discoverable: Bool
    /// Server-ranked, biggest lever first.
    public let levers: [Lever]
    public let looks: LookCounts
    /// Inputs that do NOT affect discovery today, stated plainly.
    public let notMeasured: [String]

    public struct Action: Decodable, Sendable, Identifiable {
        public let label: String
        /// Web path for the fix. Native does not navigate on it yet — see
        /// ProVisibilityView; the label is written to stand alone as guidance.
        public let href: String
        public var id: String { "\(href):\(label)" }
    }

    public struct Lever: Decodable, Sendable, Identifiable {
        /// Stable server key (BOOKABLE, AVAILABILITY, …). Kept as a String on
        /// purpose: the screen renders generically from status + copy, so a new
        /// server-side lever needs no client release.
        public let key: String
        public let status: ProVisibilityStatus
        public let headline: String
        public let detail: String
        public let actions: [Action]
        public var id: String { key }
    }

    public struct LookCounts: Decodable, Sendable {
        public let feedEligibleCount: Int
        public let pendingReviewCount: Int
        public let rejectedCount: Int
        public let draftCount: Int
        public let distinctTagCount: Int
        public let distinctServiceCount: Int
    }
}

/// Mirrors the server's status ladder.
///
/// `unknown` is a real state, not an error case: every signal behind this screen
/// is cron-populated, so "we haven't measured this yet" must render as exactly
/// that and never as the pro's failing. It doubles as the decode fallback, so a
/// status added server-side degrades to "not measured yet" instead of failing
/// the whole screen.
public enum ProVisibilityStatus: String, Decodable, Sendable {
    case good = "GOOD"
    case attention = "ATTENTION"
    case action = "ACTION"
    case unknown = "UNKNOWN"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProVisibilityStatus(rawValue: raw) ?? .unknown
    }
}

struct ProVisibilityResponse: Decodable, Sendable {
    let visibility: ProVisibilityHealth
}
