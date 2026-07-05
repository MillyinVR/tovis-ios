import Foundation

/// A pro's appointment-reminder cadence (web `GET/PUT /pro/reminder-settings`).
/// Lets the pro choose which client reminders fire ahead of a booking. Not
/// flag-gated — reminders already ship.
public struct ProReminderSettings: Decodable, Sendable {
    /// Master opt-in. While false, no reminders are scheduled for this pro.
    public let enabled: Bool
    /// Days-before-appointment offsets that fire a reminder (e.g. [7, 3, 1]).
    public let offsetDays: [Int]
}

/// One selectable offset, for rendering the cadence menu (server-driven).
public struct ReminderOffsetOption: Decodable, Sendable, Identifiable {
    public let days: Int
    public let label: String
    public var id: Int { days }
}

public struct ProReminderSettingsResponse: Decodable, Sendable {
    public let settings: ProReminderSettings
    public let options: [ReminderOffsetOption]
}

struct ProReminderSettingsUpdate: Encodable, Sendable {
    let enabled: Bool
    let offsetDays: [Int]
}
