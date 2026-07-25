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

/// One calendar occupancy — a booking, a personal block, or a client's live
/// checkout reservation. The discriminator is `kind`
/// ("BOOKING" | "BLOCK" | "HOLD").
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
    ///
    /// ⚠️ This is the *fallback* action, not the primary one — following it books
    /// the appointment outright. Prefer `canOfferWaitlistTime` + the offer sheet,
    /// which proposes a time the client confirms (and which reserves the slot
    /// meanwhile). Web's `ManagementModal` orders the two the same way.
    public let offerHref: String?
    /// Waitlist rows only: the bare waitlist entry id (the row's `id` is namespaced
    /// `waitlist:{id}`), which `POST /pro/waitlist/{entryId}/offer` expects.
    public let waitlistEntryId: String?
    /// Waitlist rows only: the service the client is waiting for.
    public let serviceId: String?
    /// Waitlist rows only: the pro's active offering for `serviceId`, or nil when
    /// they have none — in which case there is nothing to offer at all.
    public let offeringId: String?
    /// Waitlist rows only: a time already offered to this client and still
    /// awaiting their answer. Present ⇒ show it instead of an offer action, so the
    /// pro can't quietly stack a second offer on the same entry.
    public let pendingOffer: ProWaitlistPendingOffer?

    public var isBooking: Bool { kind == "BOOKING" }
    public var isBlock: Bool { kind == "BLOCK" }
    public var isWaitlist: Bool { status == "WAITLIST" }

    /// A client's LIVE checkout reservation (B5) — read-only occupancy, so the
    /// pro's day tells the truth about what their time is doing.
    ///
    /// Deliberately anonymous server-side: `clientName` is a fixed label and no
    /// `clientProfileId` is sent, because a hold means somebody is mid-checkout
    /// this minute and the pro is told the slot is spoken for, not who is
    /// hesitating over it. It cannot be opened, dragged or resized — there is no
    /// pro-facing endpoint that takes a hold id, and it expires on its own.
    ///
    /// ⚠️ A hold is NOT a block. It must never fall into an `isBlock ? … : …`
    /// else-branch that assumes "booking", nor into a block's tap/edit path.
    public var isHold: Bool { kind == "HOLD" }

    /// The bare block id for block operations (`GET`/`PATCH`/`DELETE …/blocked/{id}`),
    /// which expect the un-namespaced id. Prefers the API's `blockId`, else strips a
    /// `block:` prefix off `id`, else falls back to `id`. Only meaningful for blocks.
    public var calendarBlockId: String {
        if let blockId, !blockId.isEmpty { return blockId }
        let prefix = "block:"
        if id.hasPrefix(prefix) { return String(id.dropFirst(prefix.count)) }
        return id
    }

    /// Whether this row can be offered a concrete time the client then confirms.
    /// Mirrors web `ManagementModal`'s `canOfferTime`: a waitlist row that carries
    /// both an entry id and an active offering. A row without an offering has
    /// nothing bookable behind it, so neither platform offers an action for it.
    public var canOfferWaitlistTime: Bool {
        isWaitlist
            && !(waitlistEntryId?.isEmpty ?? true)
            && !(serviceId?.isEmpty ?? true)
            && !(offeringId?.isEmpty ?? true)
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
