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

    public init(bookings: Int, blocked: Bool) {
        self.bookings = bookings
        self.blocked = blocked
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
    /// Keyed by local "yyyy-MM-dd". A day with nothing on it is OMITTED, not
    /// zero-filled — treat a missing key as free.
    public let days: [String: ProBusyDay]

    public init(tz: String, from: String, to: String, days: [String: ProBusyDay]) {
        self.tz = tz
        self.from = from
        self.to = to
        self.days = days
    }
}
