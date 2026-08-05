import Foundation

// Wire models for the PRO bookings list — GET /api/v1/pro/bookings (tovis-app
// PR #435). Mirrors `ProBookingsListResponse` from lib/pro/proBookingsList.ts:
// today/upcoming/past/cancelled buckets + at-a-glance stats, honoring `?status=`.
// Money fields are decimal strings ("120.00"); instants are ISO-8601 UTC, but
// each row also carries a server-formatted `whenLabel` (in the booking's zone).

/// `GET /api/v1/pro/bookings` → `{ ok, scheduleTimeZone, statusFilter, stats,
/// today, upcoming, past, cancelled }` (envelope's `ok` ignored).
public struct ProBookingsListResponse: Decodable, Sendable {
    public let scheduleTimeZone: String
    public let statusFilter: String
    public let stats: ProBookingsListStats
    public let today: [ProBookingListItem]
    public let upcoming: [ProBookingListItem]
    public let past: [ProBookingListItem]
    public let cancelled: [ProBookingListItem]
}

public struct ProBookingsListStats: Decodable, Sendable {
    public let today: Int
    public let inSession: Int
    public let paymentDue: Int
}

public struct ProBookingListItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let statusLabel: String
    public let sessionStep: String?
    public let scheduledFor: String
    public let timeZone: String
    /// Server-formatted appointment line, already in the booking's timezone.
    public let whenLabel: String
    public let serviceName: String
    public let addOnNames: [String]
    public let durationMinutes: Int
    /// Decimal string ("120.00") or null when nothing is computable.
    public let total: String?
    public let client: ProBookingListClient
    public let location: ProBookingListLocation
    /// Aftercare sent but payment/checkout not closed — the "Payment due" surface.
    public let needsCloseout: Bool
    public let startedAt: String?
    public let finishedAt: String?
    /// The at-a-glance payment state (K1/K2), derived by web's ONE helper and
    /// rendered verbatim (`display` hides unknown kinds). Optional so the app
    /// keeps decoding today's prod payloads until web #787 deploys.
    public let paymentBadge: ProPaymentBadge?
    /// The NR/NNR/RR/RNR client-relationship mark (K5/K6) — a per-booking
    /// SNAPSHOT mapped server-side by the one helper and rendered verbatim.
    /// Optional so the app keeps decoding payloads from a server that predates
    /// web #797.
    public let relationshipBadge: ProRelationshipBadge?
    /// Whether the CLIENT said they're coming (K11/K13) — the words behind the
    /// calendar tile's corner glyph, derived server-side and printed verbatim.
    /// Optional AND omitted whenever nobody asked (every row while the loop
    /// flag is off), so a payload from a server that predates web #806 decodes
    /// identically to one from a server that has it.
    public let clientConfirmation: ProClientConfirmation?

    public var isInProgress: Bool { status.uppercased() == "IN_PROGRESS" }
}

public struct ProBookingListClient: Decodable, Sendable {
    public let id: String
    public let fullName: String
    public let email: String?
    public let phone: String?
    public let canViewClient: Bool
    /// The client's public `@handle`, or nil when they have no public profile.
    ///
    /// A SEPARATE axis from `canViewClient`: that one says whether this pro may
    /// open the private CHART, this one says whether a world-readable
    /// `/u/{handle}` page exists at all. A pro past their 30-day chart window
    /// looking at a public client gets `canViewClient == false` AND a handle —
    /// which is exactly the row that used to be a dead end on this screen.
    ///
    /// Optional on the wire so a build talking to a backend that predates the
    /// field decodes unchanged rather than failing the whole list.
    public let publicProfileHandle: String?
}

public struct ProBookingListLocation: Decodable, Sendable {
    public let formattedAddress: String?
    public let lat: Double?
    public let lng: Double?
    public let isMobile: Bool
}
