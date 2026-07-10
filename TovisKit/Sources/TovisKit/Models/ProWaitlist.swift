import Foundation

// Wire models for the PRO waitlist-outreach workspace (web `/pro/waitlist`) — the
// clients waiting for this pro's services, grouped by service and FIFO-ranked (the
// client who joined first is rank #1 within their service). Backed by a route that
// already exists, so this is an iOS-only port — no backend change:
//   • GET /api/v1/pro/waitlist   → { services: [group], total }
// The pro works the list top-down to fill a spot, messaging whoever they like. The
// human preference label ("Any time", "Morning", "Jul 5", "9:00 AM–12:00 PM") is
// server-formatted (`lib/waitlist/preferenceLabel`) so native renders it verbatim;
// `joinedAt` is an ISO-8601 UTC instant resolved to a display date at the edge.

/// The whole outreach feed: the per-service groups plus the total number of active
/// waitlist rows. `total` counts every active entry (matching the route, which
/// derives it from the row count) — the empty state keys on `total == 0`, as web does.
public struct ProWaitlistOutreach: Decodable, Sendable {
    public let services: [ProWaitlistServiceGroup]
    public let total: Int

    public init(services: [ProWaitlistServiceGroup], total: Int) {
        self.services = services
        self.total = total
    }

    /// True when no one is waiting (mirrors web's `total === 0` empty state).
    public var isEmpty: Bool { total == 0 }
}

/// One service's waiting clients, in FIFO (join) order.
public struct ProWaitlistServiceGroup: Decodable, Sendable, Identifiable {
    public let serviceId: String
    public let serviceName: String
    public let entries: [ProWaitlistEntry]

    public var id: String { serviceId }

    public init(serviceId: String, serviceName: String, entries: [ProWaitlistEntry]) {
        self.serviceId = serviceId
        self.serviceName = serviceName
        self.entries = entries
    }
}

/// A single waiting client. `rank` is the honest position within the service group
/// (who has waited longest), `preferenceLabel` is server-formatted, `joinedAt` is
/// an ISO-8601 UTC instant.
public struct ProWaitlistEntry: Decodable, Sendable, Identifiable {
    public let rank: Int
    public let waitlistEntryId: String
    public let clientName: String
    public let avatarUrl: String?
    public let preferenceLabel: String
    public let joinedAt: String

    public var id: String { waitlistEntryId }

    public init(
        rank: Int,
        waitlistEntryId: String,
        clientName: String,
        avatarUrl: String?,
        preferenceLabel: String,
        joinedAt: String
    ) {
        self.rank = rank
        self.waitlistEntryId = waitlistEntryId
        self.clientName = clientName
        self.avatarUrl = avatarUrl
        self.preferenceLabel = preferenceLabel
        self.joinedAt = joinedAt
    }
}
