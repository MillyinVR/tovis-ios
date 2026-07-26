import Foundation

// Wire models for the PRO weekly working hours — GET/POST /api/v1/pro/working-hours.
// Mirrors the inline shape in the route (a 7-key map of {enabled, start"HH:MM",
// end"HH:MM"}). Inline backend shape; decode-only. See docs/PRO-BACKEND-CONTRACTS.md.

/// `GET`/`POST /api/v1/pro/working-hours` → the resolved week + context.
public struct ProWorkingHoursResponse: Decodable, Sendable {
    public let workingHours: ProWeekHours
    public let locationType: String?
    public let locationId: String?
    /// True when the pro has no saved hours and the server returned a default week.
    public let usedDefault: Bool?
    /// POST only. The bookings this save just put outside the pro's published
    /// hours — informational, the save always succeeded (B8, Tori 2026-07-25).
    ///
    /// Three-valued on the wire and all three mean different things: ABSENT
    /// (the save changed no hours), `null` (the server could not compute the
    /// report), or a report. Only a report is shown; a warning nobody could
    /// compute must not render as a reassuring "0".
    public let strandedBookings: ProStrandedBookings?
}

/// The bookings a working-hours save stranded. `total` counts them all; `items`
/// is the server-capped list, soonest first.
public struct ProStrandedBookings: Decodable, Sendable, Equatable {
    public let total: Int
    public let items: [ProStrandedBooking]
}

/// One stranded booking, as the pro's own calendar would show it.
public struct ProStrandedBooking: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    /// ISO-8601 UTC instant — render it in `timeZone`, not the device's.
    public let scheduledFor: String
    /// The appointment itself; the buffer is deliberately not counted.
    public let durationMinutes: Int
    public let locationId: String
    /// IANA zone of that booking's location.
    public let timeZone: String
    public let clientName: String
    public let serviceName: String?
}

/// One day's hours. `start`/`end` are "HH:MM" (24h) in the location's zone.
public struct ProDayHours: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var start: String
    public var end: String

    public init(enabled: Bool, start: String, end: String) {
        self.enabled = enabled
        self.start = start
        self.end = end
    }
}

/// The seven days, keyed exactly as the backend expects (sun…sat).
public struct ProWeekHours: Codable, Sendable, Equatable {
    public var sun: ProDayHours
    public var mon: ProDayHours
    public var tue: ProDayHours
    public var wed: ProDayHours
    public var thu: ProDayHours
    public var fri: ProDayHours
    public var sat: ProDayHours

    public init(
        sun: ProDayHours, mon: ProDayHours, tue: ProDayHours, wed: ProDayHours,
        thu: ProDayHours, fri: ProDayHours, sat: ProDayHours
    ) {
        self.sun = sun; self.mon = mon; self.tue = tue; self.wed = wed
        self.thu = thu; self.fri = fri; self.sat = sat
    }
}

/// POST body — `{ workingHours }`.
struct ProWorkingHoursUpdateRequest: Encodable {
    let workingHours: ProWeekHours
}
