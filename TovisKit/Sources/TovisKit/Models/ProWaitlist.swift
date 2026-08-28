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
    /// MOBILE offers only: how far the pro would travel and roughly where.
    ///
    /// 🔴 This is ALL the server sends about the destination while the offer is
    /// PENDING, and that is enforced server-side — the response carries no
    /// address and no coordinates to decode, whatever this app renders. The exact
    /// address arrives only once the client accepts, on the booking that creates.
    ///
    /// nil for an in-salon offer (the client is coming to the pro), and nil from
    /// a server predating this field.
    public let travel: ProWaitlistOfferTravel?

    public init(
        id: String,
        startsAt: String,
        locationType: String,
        travel: ProWaitlistOfferTravel? = nil
    ) {
        self.id = id
        self.startsAt = startsAt
        self.locationType = locationType
        self.travel = travel
    }
}

/// The trip a PENDING mobile offer would involve, as the pro is allowed to see it.
///
/// `summary` is the whole sentence, composed by the server ("1.9 mi away ·
/// Coronado, CA") and rendered VERBATIM — the wording of a privacy boundary is
/// not re-authored per platform, the same rule `preferenceLabel` follows.
/// `distanceMiles` / `areaLabel` are its parts, for a surface that needs them
/// separately; either may be nil, and so may `summary` when neither is known.
public struct ProWaitlistOfferTravel: Decodable, Sendable {
    public let distanceMiles: Double?
    public let areaLabel: String?
    public let summary: String?

    public init(distanceMiles: Double?, areaLabel: String?, summary: String?) {
        self.distanceMiles = distanceMiles
        self.areaLabel = areaLabel
        self.summary = summary
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
/// waitlist entry, so neither travels here — only the chosen slot, the mode, and
/// the PRO's own location for that mode. Times are ISO-8601 instants;
/// `durationMinutes` is sent alongside `endsAt` so the server doesn't have to
/// re-derive it (it falls back to `endsAt - scheduledFor`).
///
/// 🔴 There is no client-address field, and there must never be one. For a MOBILE
/// offer the destination is resolved server-side from the waitlist entry; asking
/// this device to name it would mean handing the pro an address they are not yet
/// entitled to.
struct ProWaitlistOfferRequest: Encodable {
    let scheduledFor: String
    let endsAt: String
    let locationId: String
    let locationType: String
    let durationMinutes: Int
}

// MARK: - What may be offered (GET /api/v1/pro/waitlist/{entryId}/offer)

/// One mode the SERVER says this pro may offer this entry a time in, and the
/// location of their own it is anchored to.
///
/// Server-answered on purpose. Both apps used to derive this locally — find a
/// bookable SALON/SUITE, send `locationType: "SALON"` — so a mobile-only pro had
/// no offer action at all and no way to learn why. `loadWaitlistHostability` and
/// `pickBookableLocation` are the two rules, and the POST re-runs both under the
/// professional's lock, so an option here is one the send accepts.
public struct ProWaitlistOfferOption: Decodable, Sendable, Identifiable {
    public let locationType: String
    public let locationId: String
    public let locationName: String?
    public let timeZone: String
    public let durationMinutes: Int

    public var id: String { "\(locationType):\(locationId)" }

    public var isMobile: Bool { locationType == "MOBILE" }

    public init(
        locationType: String,
        locationId: String,
        locationName: String?,
        timeZone: String,
        durationMinutes: Int
    ) {
        self.locationType = locationType
        self.locationId = locationId
        self.locationName = locationName
        self.timeZone = timeZone
        self.durationMinutes = durationMinutes
    }
}

/// `GET /api/v1/pro/waitlist/{entryId}/offer` → what this pro may offer.
///
/// `blockedReason` is a pro-facing sentence for the empty state — "there is
/// nothing to offer, and here is what to fix" — not an error. It is non-nil
/// exactly when `options` is empty.
public struct ProWaitlistOfferOptions: Decodable, Sendable {
    public let offeringId: String?
    public let options: [ProWaitlistOfferOption]
    public let blockedReason: String?

    public init(
        offeringId: String?,
        options: [ProWaitlistOfferOption],
        blockedReason: String?
    ) {
        self.offeringId = offeringId
        self.options = options
        self.blockedReason = blockedReason
    }
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
