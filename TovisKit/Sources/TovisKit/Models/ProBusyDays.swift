import Foundation

// Wire models for GET /api/v1/pro/availability/busy-days — the PRO's own
// commitments bucketed per calendar day. Mirrors the backend DTO
// `ProAvailabilityBusyDaysOk` / `ProBusyDayDTO` (lib/dto/proAvailability.ts),
// which the route enforces via `satisfies`, so the contract job validates the
// fixture below against the same declaration this decodes.
//
// Deliberately service-agnostic and CROSS-LOCATION: it answers "which days am
// I already committed on", not "can this service be booked here" — that is
// /api/v1/availability/day (and `BookingService.day`). Carries no client names
// or ids, only counts, so a date-picker overlay leaks nothing.

/// One calendar day's commitments, in the response's `tz`.
public struct ProBusyDay: Decodable, Sendable, Equatable {
    /// Occupying bookings (the server's shared blocking-status set) that start
    /// on this local day.
    public let bookings: Int
    /// Whether a calendar block touches this local day.
    public let blocked: Bool
    /// Bookable START TIMES left on this local day for the service the request
    /// named — "can I still fit someone in", as opposed to the two fields
    /// above, which only say how full the day already is (R4).
    ///
    /// Present ONLY when the request carried a service context AND the response
    /// envelope says `openSlots?.computed == true`; then it is present on EVERY
    /// day in range, zeroes included, because a fully-booked day and a day the
    /// server never counted must not look alike. Read the envelope first —
    /// don't infer "not counted" from a nil here.
    public let openSlots: Int?

    public init(bookings: Int, blocked: Bool, openSlots: Int? = nil) {
        self.bookings = bookings
        self.blocked = blocked
        self.openSlots = openSlots
    }
}

/// What to count open slots FOR (R4) — the request half of the overlay.
///
/// There is deliberately no `professionalId`: the route scopes everything to
/// the authenticated pro, and these params only narrow which of THEIR offerings
/// is being counted.
public struct ProBusyDaysSlotContext: Sendable, Equatable {
    public let serviceId: String
    public let locationType: String?
    public let locationId: String?
    /// Selected add-on link ids — they widen the appointment, so they change
    /// the count.
    public let addOnIds: [String]
    /// Set when the pro is MOVING an existing booking. The server then sizes the
    /// count from that booking's committed width rather than the offering's, and
    /// stops the booking blocking its own day — without it the day the
    /// appointment already sits on reads as fuller than it is.
    public let rescheduleBookingId: String?

    public init(
        serviceId: String,
        locationType: String? = nil,
        locationId: String? = nil,
        addOnIds: [String] = [],
        rescheduleBookingId: String? = nil
    ) {
        self.serviceId = serviceId
        self.locationType = locationType
        self.locationId = locationId
        self.addOnIds = addOnIds
        self.rescheduleBookingId = rescheduleBookingId
    }

    public var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "serviceId", value: serviceId)]
        if let locationType, !locationType.isEmpty {
            items.append(URLQueryItem(name: "locationType", value: locationType))
        }
        if let locationId, !locationId.isEmpty {
            items.append(URLQueryItem(name: "locationId", value: locationId))
        }
        if !addOnIds.isEmpty {
            items.append(URLQueryItem(name: "addOnIds", value: addOnIds.joined(separator: ",")))
        }
        if let rescheduleBookingId, !rescheduleBookingId.isEmpty {
            items.append(
                URLQueryItem(name: "rescheduleBookingId", value: rescheduleBookingId))
        }
        return items
    }
}

/// Whether the open-slot overlay was computed, for what, and why not when it
/// wasn't. Mirrors the backend `ProOpenSlotContextDTO`.
public struct ProOpenSlotContext: Decodable, Sendable, Equatable {
    /// True when every day in `[from, to]` carries an `openSlots` count.
    public let computed: Bool
    /// The appointment width the counts were computed for. A reschedule is
    /// sized from the BOOKING, everything else from the offering plus its
    /// add-ons, so this is echoed rather than assumed. nil when nothing was
    /// computed.
    public let durationMinutes: Int?
    /// Why counts are missing when `computed` is false — a booking error code
    /// or "SERVICE_NOT_FOUND". Treat it as a reason to HIDE the overlay, not to
    /// fail: the day picker still works without counts.
    public let reason: String?

    public init(computed: Bool, durationMinutes: Int?, reason: String?) {
        self.computed = computed
        self.durationMinutes = durationMinutes
        self.reason = reason
    }
}

/// `GET /api/v1/pro/availability/busy-days` → day buckets for a date range.
public struct ProBusyDaysResponse: Decodable, Sendable {
    /// The IANA zone the buckets were computed in (echoed, may differ from the
    /// requested one when that was missing or invalid).
    public let tz: String
    /// Echoed range, inclusive "yyyy-MM-dd". `to` may be CLAMPED by the server
    /// when the requested range was longer than its cap — read it back rather
    /// than assuming the request was honored whole.
    public let from: String
    public let to: String
    /// Keyed by local "yyyy-MM-dd".
    ///
    /// Density depends on the mode. Busy-only (no service context requested): a
    /// day with nothing on it is OMITTED — treat a missing key as free. With
    /// open-slot counts computed: EVERY day in range is present, because a zero
    /// count is information.
    public let days: [String: ProBusyDay]
    /// The open-slot overlay's state (R4). nil when the request carried no
    /// service context at all — the classic "which days am I busy" call — and
    /// also when talking to a server that predates R4, which is why this is
    /// optional rather than required.
    public let openSlots: ProOpenSlotContext?

    public init(
        tz: String,
        from: String,
        to: String,
        days: [String: ProBusyDay],
        openSlots: ProOpenSlotContext? = nil
    ) {
        self.tz = tz
        self.from = from
        self.to = to
        self.days = days
        self.openSlots = openSlots
    }
}
