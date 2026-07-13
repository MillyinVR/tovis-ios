import Foundation

// Wire models for the PRO calendar — GET /api/v1/pro/calendar.
// Mirrors the inline payload in `app/api/v1/pro/calendar/route.ts` (CalendarEvent
// = BookingEvent | BlockEvent, CalendarStats, the management buckets). Only the
// subset the native agenda renders is modeled; unknown keys are ignored and
// nullable fields are Swift optionals (BLOCK events carry no timeZone/locationType).

/// `GET /api/v1/pro/calendar` → the calendar payload (envelope spread).
public struct ProCalendarResponse: Decodable, Sendable {
    public let timeZone: String?
    public let viewportTimeZone: String?
    public let needsTimeZoneSetup: Bool?
    public let events: [ProCalendarEvent]
    public let stats: ProCalendarStats
    public let management: ProCalendarManagement
    /// Whether new bookings auto-accept (drives the calendar's auto-accept bar).
    public let autoAcceptBookings: Bool?
}

/// `PATCH /api/v1/pro/settings` → `{ professionalProfile: { autoAcceptBookings } }`.
public struct ProSettingsResponse: Decodable, Sendable {
    public struct Profile: Decodable, Sendable {
        public let autoAcceptBookings: Bool
    }
    public let professionalProfile: Profile
}

/// `PATCH /api/v1/pro/settings` body — currently just the auto-accept flag.
struct ProSettingsUpdateRequest: Encodable {
    let autoAcceptBookings: Bool
}

/// One calendar occupancy — a booking or a personal block. The discriminator is
/// `kind` ("BOOKING" | "BLOCK").
public struct ProCalendarEvent: Decodable, Sendable, Identifiable {
    public let id: String
    /// BLOCK events only: the bare block id. The calendar API namespaces a block
    /// event's `id` as `block:{id}` (so it can't collide with a booking id) and
    /// also sends the bare `blockId`; the block routes (`…/blocked/{id}`) expect
    /// the bare id. nil for bookings. Use `calendarBlockId` to resolve it safely.
    public let blockId: String?
    public let kind: String
    public let startsAt: String
    public let endsAt: String
    public let title: String
    public let clientName: String
    public let status: String
    public let durationMinutes: Int
    /// Booking events carry the resolved viewport timezone; blocks don't.
    public let timeZone: String?
    public let locationType: String?
    /// The event's local date in the viewport zone — used to group the agenda.
    public let localDateKey: String
    /// ClientProfile id — present only when the pro may open this client's chart
    /// (server-gated, so nil means "render the name as plain text, no link").
    public let clientProfileId: String?
    /// Waitlist rows only: human label for the client's preferred time
    /// (e.g. "Any time", "Morning", "Jun 14").
    public let preferenceLabel: String?
    /// Waitlist rows only: web deep-link (`/pro/bookings/new?...`) carrying the
    /// client + offering the pro can offer a matching slot for. nil when the pro
    /// has no active offering for the requested service.
    public let offerHref: String?

    public var isBooking: Bool { kind == "BOOKING" }
    public var isBlock: Bool { kind == "BLOCK" }
    public var isWaitlist: Bool { status == "WAITLIST" }

    /// The bare block id for block operations (`GET`/`PATCH`/`DELETE …/blocked/{id}`),
    /// which expect the un-namespaced id. Prefers the API's `blockId`, else strips a
    /// `block:` prefix off `id`, else falls back to `id`. Only meaningful for blocks.
    public var calendarBlockId: String {
        if let blockId, !blockId.isEmpty { return blockId }
        let prefix = "block:"
        if id.hasPrefix(prefix) { return String(id.dropFirst(prefix.count)) }
        return id
    }
}

public struct ProCalendarStats: Decodable, Sendable {
    public let todaysBookings: Int
    public let availableHours: Double?
    public let pendingRequests: Int
    public let blockedHours: Double
}

/// The management buckets the web surfaces in the side panel / stats tiles.
public struct ProCalendarManagement: Decodable, Sendable {
    public let todaysBookings: [ProCalendarEvent]
    public let pendingRequests: [ProCalendarEvent]
    public let waitlistToday: [ProCalendarEvent]
    public let blockedToday: [ProCalendarEvent]
}
