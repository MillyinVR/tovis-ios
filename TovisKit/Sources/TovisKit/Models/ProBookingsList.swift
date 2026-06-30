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

    public var isInProgress: Bool { status.uppercased() == "IN_PROGRESS" }
}

public struct ProBookingListClient: Decodable, Sendable {
    public let id: String
    public let fullName: String
    public let email: String?
    public let phone: String?
    public let canViewClient: Bool
}

public struct ProBookingListLocation: Decodable, Sendable {
    public let formattedAddress: String?
    public let lat: Double?
    public let lng: Double?
    public let isMobile: Bool
}
