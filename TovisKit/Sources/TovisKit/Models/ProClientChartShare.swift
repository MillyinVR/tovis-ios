import Foundation

/// W5 chart consent, as the PRO sees it —
/// `GET/POST /api/v1/pro/clients/{id}/chart-share`.
///
/// One row per (client, pro), so "may this pro read this chart right now" always
/// has exactly one answer. The pro can only ever move it to `requested`; every
/// other transition belongs to the client, which is the whole point — a consent
/// control the subject cannot reach is not consent.
///
/// 🔴 `granted` is the ONLY status that opens the chart. `requested` grants
/// nothing; a pro asking is not a pro allowed.
public struct ProClientChartShare: Decodable, Sendable, Equatable {
    public enum Status: String, Decodable, Sendable {
        /// The pro asked; the client hasn't answered. Grants nothing.
        case requested = "REQUESTED"
        /// The client said yes. The only value that opens the chart.
        case granted = "GRANTED"
        /// The client said no. Terminal — the pro cannot ask again.
        case declined = "DECLINED"
        /// The client granted, then took it back. Re-askable after a cooldown.
        case revoked = "REVOKED"
    }

    /// Null when the pair has no row at all — nobody has asked and nobody has
    /// shared. Distinct from `.declined`, which is an answer.
    public let status: Status?
    public let requestedAt: Date?
    public let respondedAt: Date?
    public let revokedAt: Date?
    /// Whether the chart is open right now. Sent by the server so the client
    /// never re-derives the visibility policy — see the route's comment.
    public let canViewChart: Bool?

    /// Whether the pro may press "Request access" right now.
    ///
    /// 🔴 Comes from the SERVER (`chartShareRequestBlock`, the same predicate
    /// the POST runs) and is never recomputed here. The re-request cooldown
    /// after a revoke is a duration this app does not know, so deriving this
    /// from `status` alone would offer a button the POST answers with 409 —
    /// and would drift silently the day the cooldown changes.
    ///
    /// Absent on an older server; `proCanAsk` treats that as "let them try",
    /// because the server refuses authoritatively either way.
    public let canRequest: Bool?

    /// Why not, when `canRequest` is false:
    /// `ALREADY_GRANTED` | `REQUEST_PENDING` | `DECLINED` | `COOLDOWN`.
    public let requestBlockedReason: String?

    public init(
        status: Status? = nil,
        requestedAt: Date? = nil,
        respondedAt: Date? = nil,
        revokedAt: Date? = nil,
        canViewChart: Bool? = nil,
        canRequest: Bool? = nil,
        requestBlockedReason: String? = nil
    ) {
        self.status = status
        self.requestedAt = requestedAt
        self.respondedAt = respondedAt
        self.revokedAt = revokedAt
        self.canViewChart = canViewChart
        self.canRequest = canRequest
        self.requestBlockedReason = requestBlockedReason
    }

    /// Show the ask? Defaults to true when the server didn't say — the POST is
    /// the real gate, and hiding the only way forward on a missing field would
    /// strand the pro with no route out of the refusal.
    public var proCanAsk: Bool { canRequest ?? true }

    /// Pro-facing copy for a blocked ask. Nil when there is nothing to explain.
    ///
    /// A blocked state renders as TEXT, never a disabled button — a control
    /// that cannot act still reads as one the pro is failing to use, and for a
    /// decline it would make the client's answer look negotiable.
    public var blockedCopy: String? {
        switch requestBlockedReason {
        case "REQUEST_PENDING":
            return "Asked — waiting on them. You’ll get a notification if they say yes."
        case "DECLINED":
            return "They declined to share their chart."
        case "COOLDOWN":
            return "They recently turned off chart sharing. You can ask again in a while."
        case "ALREADY_GRANTED":
            return "They already share their chart with you."
        default:
            return nil
        }
    }
}

/// `{ chartShare: … }` — the envelope both the GET and the POST answer with.
public struct ProClientChartShareResponse: Decodable, Sendable {
    public let chartShare: ProClientChartShare
}
