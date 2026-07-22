import Foundation

// Wire models for the PRO waitlist-outreach workspace (web `/pro/waitlist`) — the
// clients waiting for this pro's services, grouped by service and FIFO-ranked (the
// client who joined first is rank #1 within their service). Backed by a route that
// already exists, so this is an iOS-only port — no backend change:
//   • GET  /api/v1/pro/waitlist                 → { services: [group], total }
//   • POST /api/v1/pro/waitlist/{entryId}/offer → { ok, offer }  (offer a time)
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

/// A time already offered to this client that they can still confirm. The server
/// filters it by the same rule the confirm applies (PENDING and not expired), so
/// a value here always means "outstanding right now".
///
/// Since F14 an offer also places a BookingHold over the slot, so a row carrying
/// one is the pro's explanation for that time being missing from their own
/// availability. Optional on the wire: a build talking to a server from before
/// F14 simply sees `nil`.
public struct ProWaitlistPendingOffer: Decodable, Sendable, Identifiable {
    public let id: String
    public let startsAt: String
    public let locationType: String

    public init(id: String, startsAt: String, locationType: String) {
        self.id = id
        self.startsAt = startsAt
        self.locationType = locationType
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
    /// A still-confirmable time already offered to this client, or nil.
    public let pendingOffer: ProWaitlistPendingOffer?

    public var id: String { waitlistEntryId }

    public init(
        rank: Int,
        waitlistEntryId: String,
        clientName: String,
        avatarUrl: String?,
        preferenceLabel: String,
        joinedAt: String,
        pendingOffer: ProWaitlistPendingOffer? = nil
    ) {
        self.rank = rank
        self.waitlistEntryId = waitlistEntryId
        self.clientName = clientName
        self.avatarUrl = avatarUrl
        self.preferenceLabel = preferenceLabel
        self.joinedAt = joinedAt
        self.pendingOffer = pendingOffer
    }
}

// MARK: - Offer a time (POST /api/v1/pro/waitlist/{entryId}/offer)

/// The request body for offering a waitlisted client a concrete appointment time
/// (web `WaitlistOfferModal`). The route derives the client + service from the
/// waitlist entry, so neither travels here — only the chosen slot + in-salon
/// location. `locationType` is always `SALON` (in-salon offers only, v1). Times
/// are ISO-8601 instants; `durationMinutes` is sent alongside `endsAt` so the
/// server doesn't have to re-derive it (it falls back to `endsAt - scheduledFor`).
struct ProWaitlistOfferRequest: Encodable {
    let scheduledFor: String
    let endsAt: String
    let locationId: String
    let locationType: String
    let durationMinutes: Int
}

/// `POST /api/v1/pro/waitlist/{entryId}/offer` → `{ ok, offer }`.
struct ProWaitlistOfferResponse: Decodable {
    let offer: ProWaitlistOffer
}

/// The PENDING offer created by proposing a time to a waitlisted client. It does
/// NOT book anything — the client Confirms/Declines before it becomes a booking —
/// so `status` starts `PENDING`. Times are ISO-8601 UTC instants echoed back from
/// the server for the caller's confirmation.
public struct ProWaitlistOffer: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let startsAt: String
    public let endsAt: String
    public let locationType: String

    public init(
        id: String,
        status: String,
        startsAt: String,
        endsAt: String,
        locationType: String
    ) {
        self.id = id
        self.status = status
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.locationType = locationType
    }
}
