import Foundation

/// A pro's appointment-reminder cadence (web `GET/PUT /pro/reminder-settings`).
/// A pro builds a fully custom list of reminders, each with an arbitrary lead
/// time (any number of days OR hours before a booking). The scalar unit of
/// identity is minutes before the appointment (`offsetMinutes`). Not flag-gated —
/// reminders already ship.
public struct ProReminderSettings: Decodable, Sendable {
    /// Master opt-in. While false, no reminders are scheduled for this pro.
    public let enabled: Bool
    /// Lead-time offsets that fire a reminder, in minutes (sorted desc, deduped).
    public let offsetMinutes: [Int]
    /// The same offsets, humanized + structured for display/editing (longest first).
    public let leads: [ReminderLead]
}

/// One configured reminder lead time: the scalar SSOT (`minutes`) plus a
/// structured value/unit + a humanized label for display + editing. `unit` is a
/// server-driven raw string ("days" / "hours") so a future unit never fails decode.
public struct ReminderLead: Decodable, Sendable, Identifiable {
    public let minutes: Int
    public let value: Int
    public let unit: String
    public let label: String
    public var id: Int { minutes }
}

/// A suggested lead-time preset offered as a quick-add in the editor.
public struct ReminderPreset: Decodable, Sendable, Identifiable {
    public let value: Int
    public let unit: String
    public let label: String
    public var id: String { "\(value)-\(unit)" }
}

public struct ProReminderSettingsResponse: Decodable, Sendable {
    public let settings: ProReminderSettings
    /// Suggested lead-time presets the UI can offer as quick-adds.
    public let presets: [ReminderPreset]
}

/// A single reminder lead time as submitted by the editor.
public struct ReminderLeadInput: Encodable, Sendable {
    public let value: Int
    /// "days" or "hours" — converted to minutes server-side.
    public let unit: String

    public init(value: Int, unit: String) {
        self.value = value
        self.unit = unit
    }
}

struct ProReminderSettingsUpdate: Encodable, Sendable {
    let enabled: Bool
    let reminders: [ReminderLeadInput]
}
