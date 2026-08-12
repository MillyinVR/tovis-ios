import Foundation

/// W5 chart consent, as the CLIENT sees it —
/// `GET/PATCH /api/v1/client/chart-shares`.
///
/// The pro's view (`ProClientChartShare`) answers "may I read this one chart".
/// This answers the question the whole feature exists for, and the one a client
/// previously had no way to ask on the phone: **who can read my allergies, my
/// formulas and my notes — and how do I take that back.**
///
/// 🔴 The client's list is the authoritative one for them. Only `.granted`
/// means someone can read the chart right now; a `.requested` row is a pro
/// waiting, not a pro allowed.
public struct ClientChartShare: Decodable, Sendable, Equatable, Identifiable {
    public let professionalId: String
    /// Already formatted for display by the server
    /// (`formatProfessionalPublicDisplayName`) — never re-derived here, so the
    /// two clients name a pro the same way.
    public let professionalName: String
    public let avatarUrl: String?

    /// Nil when the server sent a state this build doesn't know.
    ///
    /// 🔴 Decoded leniently ON PURPOSE. A future fifth status must cost the
    /// client one unreadable row, never their entire list of who holds access —
    /// a privacy screen that fails closed to "blank" tells them nothing while
    /// looking like "nobody". Pinned by ClientChartShareWireTests.
    public let status: ChartShareStatus?

    // ISO-8601 strings, for the same reason as ProClientChartShare — see the
    // 🔴 block there.
    public let requestedAt: String?
    public let respondedAt: String?
    public let revokedAt: String?

    public var id: String { professionalId }

    /// Whether this pro can read the chart right now.
    public var grantsAccess: Bool { status?.grantsAccess == true }

    /// The line under the pro's name.
    public var statusCopy: String {
        status?.clientCopy ?? "Sharing state unavailable"
    }

    private enum CodingKeys: String, CodingKey {
        case professionalId, professionalName, avatarUrl, status
        case requestedAt, respondedAt, revokedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        professionalId = try c.decode(String.self, forKey: .professionalId)
        professionalName =
            (try? c.decode(String.self, forKey: .professionalName)) ?? "Professional"
        avatarUrl = try? c.decodeIfPresent(String.self, forKey: .avatarUrl)
        // Lenient: an unrecognised string becomes nil rather than throwing.
        status = ChartShareStatus(
            rawValue: (try? c.decodeIfPresent(String.self, forKey: .status)) ?? ""
        )
        requestedAt = try? c.decodeIfPresent(String.self, forKey: .requestedAt)
        respondedAt = try? c.decodeIfPresent(String.self, forKey: .respondedAt)
        revokedAt = try? c.decodeIfPresent(String.self, forKey: .revokedAt)
    }

    public init(
        professionalId: String,
        professionalName: String,
        avatarUrl: String? = nil,
        status: ChartShareStatus?,
        requestedAt: String? = nil,
        respondedAt: String? = nil,
        revokedAt: String? = nil
    ) {
        self.professionalId = professionalId
        self.professionalName = professionalName
        self.avatarUrl = avatarUrl
        self.status = status
        self.requestedAt = requestedAt
        self.respondedAt = respondedAt
        self.revokedAt = revokedAt
    }
}

/// `{ shares: [...] }` — the GET envelope.
public struct ClientChartSharesResponse: Decodable, Sendable {
    public let shares: [ClientChartShare]
}

/// `{ chartShare: { professionalId, status } }` — what PATCH answers with.
/// Deliberately narrower than the GET row: the write echoes the new state, it
/// does not re-send the pro's identity.
public struct ClientChartShareUpdate: Decodable, Sendable, Equatable {
    public let professionalId: String
    public let status: ChartShareStatus?

    private enum CodingKeys: String, CodingKey { case professionalId, status }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        professionalId = try c.decode(String.self, forKey: .professionalId)
        status = ChartShareStatus(
            rawValue: (try? c.decodeIfPresent(String.self, forKey: .status)) ?? ""
        )
    }

    public init(professionalId: String, status: ChartShareStatus?) {
        self.professionalId = professionalId
        self.status = status
    }
}

public struct ClientChartShareUpdateResponse: Decodable, Sendable {
    public let chartShare: ClientChartShareUpdate
}
