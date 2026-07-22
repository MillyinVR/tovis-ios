import Foundation

/// F12 — what a consultation proposal does to the appointment's END TIME, as
/// the server worked it out at proposal time.
///
/// Native counterpart of `ConsultationScheduleOutlook` in
/// `tovis-app/lib/consultation/proposalSchedule.ts`. It arrives on the 200 from
/// `POST /pro/bookings/{id}/consultation-proposal`.
///
/// Two rules carried over from the server, and from F16 before it:
///
///  * **Silent by default.** Only `pastWorkingHours` has something to say. An
///    appointment that was ALREADY running late did not become a problem
///    because a proposal was sent, and saying so would be a false alarm about a
///    pre-existing condition.
///  * **An unanswered question is never an answer.** `notChecked` is a distinct
///    state, and an outlook this build does not recognise decodes to it rather
///    than to "you're fine".
///
/// Calendar blocks are NOT here: the server refuses those outright with a 409
/// `TIME_BLOCKED`, which both call sites already render as `APIError.userMessage`.
public enum ConsultationScheduleOutlook: String, Decodable, Sendable, CaseIterable {
    /// The whole appointment, extension included, still sits inside the pro's hours.
    case withinWorkingHours = "WITHIN_WORKING_HOURS"
    /// These services are what push the end past the pro's hours.
    case pastWorkingHours = "PAST_WORKING_HOURS"
    /// The appointment was already outside the pro's hours before this proposal.
    case alreadyOutsideWorkingHours = "ALREADY_OUTSIDE_WORKING_HOURS"
    /// This location has no usable working hours, so there is nothing to judge against.
    case workingHoursMissing = "WORKING_HOURS_MISSING"
    /// Not asked, or asked and the answer did not arrive.
    case notChecked = "NOT_CHECKED"

    /// A server that has learned a new state must not silence this one: an
    /// unknown value is "we did not get an answer", never "all clear".
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConsultationScheduleOutlook(rawValue: raw) ?? .notChecked
    }

    /// What the pro is told, or nil when there is nothing worth saying.
    ///
    /// `endsAtLabel` is the new end time as a wall clock in the APPOINTMENT's
    /// zone. It is optional because the server cannot always resolve a zone, and
    /// a time rendered in the DEVICE's zone would be a lie about the
    /// appointment's — so the sentence drops the clock rather than guessing.
    ///
    /// Exhaustive with no `default`, so a new case fails the build here rather
    /// than reaching the pro as a blank line.
    public func notice(endsAtLabel: String?) -> String? {
        switch self {
        case .pastWorkingHours:
            if let endsAtLabel {
                return "Sent. With these services the appointment now runs to \(endsAtLabel) — past your working hours."
            }
            return "Sent. With these services the appointment now runs past your working hours."
        case .withinWorkingHours, .alreadyOutsideWorkingHours, .workingHoursMissing,
            .notChecked:
            return nil
        }
    }
}

/// The `schedule` object on a successful proposal send.
public struct ConsultationProposalSchedule: Decodable, Sendable {
    /// UTC instant the appointment now ends (services + buffer).
    public let endsAt: String?
    public let durationMinutes: Int?
    public let bufferMinutes: Int?
    /// The appointment's zone; nil when the server could not resolve one.
    public let timeZone: String?
    public let outlook: ConsultationScheduleOutlook?

    /// The finished sentence for this send, or nil to say nothing.
    ///
    /// No zone means no clock. `Wire`'s formatters fall back to the DEVICE zone,
    /// which is right for most surfaces and wrong here: the pro is being told
    /// when THIS APPOINTMENT ends, and a pro travelling (or a device zone that
    /// simply disagrees with the salon's) would be shown a confident wrong time.
    public var notice: String? {
        guard let outlook else { return nil }

        var label: String?
        if let endsAt, let timeZone, !timeZone.isEmpty {
            let text = Wire.timeOnly(endsAt, timeZone: timeZone)
            label = text.isEmpty ? nil : text
        }

        return outlook.notice(endsAtLabel: label)
    }
}
