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
    /// One enum for both sides of the pair — see `ChartShareStatus`. Kept as a
    /// nested alias so existing `ProClientChartShare.Status` references still
    /// compile.
    public typealias Status = ChartShareStatus

    /// Null when the pair has no row at all — nobody has asked and nobody has
    /// shared. Distinct from `.declined`, which is an answer.
    public let status: Status?

    // 🔴 ISO-8601 STRINGS, not `Date`.
    //
    // `APIClient` decodes with a plain `JSONDecoder()`, whose default date
    // strategy is `.deferredToDate` — it expects a number. The backend sends
    // `share.requestedAt?.toISOString()`, so typing these as `Date?` made the
    // WHOLE response throw the moment a timestamp stopped being null — i.e.
    // the moment a pro actually asked, which is the only time this model is
    // interesting. Every other TovisKit model types timestamps as `String` for
    // this reason. Pinned by ProChartShareWireTests.
    public let requestedAt: String?
    public let respondedAt: String?
    public let revokedAt: String?
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
        requestedAt: String? = nil,
        respondedAt: String? = nil,
        revokedAt: String? = nil,
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

    /// Pro-facing copy for a blocked ask. Nil exactly when the ask is offered.
    ///
    /// A blocked state renders as TEXT, never a disabled button — a control
    /// that cannot act still reads as one the pro is failing to use, and for a
    /// decline it would make the client's answer look negotiable.
    ///
    /// 🔴 Never nil while `proCanAsk` is false. A future server code this build
    /// cannot name would otherwise render as neither a button nor a reason —
    /// the pro would be left staring at the refusal with nothing on screen to
    /// do or to explain it. The generic line is worse copy than the specific
    /// ones and infinitely better than a blank.
    public var blockedCopy: String? {
        guard !proCanAsk else { return nil }

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
            return "You can’t ask for chart access right now."
        }
    }
}

/// `{ chartShare: … }` — the envelope both the GET and the POST answer with.
public struct ProClientChartShareResponse: Decodable, Sendable {
    public let chartShare: ProClientChartShare
}
