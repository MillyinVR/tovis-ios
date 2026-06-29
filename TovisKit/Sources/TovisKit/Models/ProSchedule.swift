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
