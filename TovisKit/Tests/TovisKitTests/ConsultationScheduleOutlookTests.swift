import Foundation
import Testing
@testable import TovisKit

// F12 — the pro-facing read of what a consultation proposal does to the
// appointment's end time. Mirrors `ConsultationForm.test.tsx` on web and the
// server states in `tovis-app/lib/consultation/proposalSchedule.ts`.
struct ConsultationScheduleOutlookTests {
    /// 2026-04-14T01:15Z is 18:15 in America/Los_Angeles.
    static let endsAtUtc = "2026-04-14T01:15:00.000Z"

    private func decodeSchedule(_ json: String) throws -> ConsultationProposalSchedule {
        try JSONDecoder().decode(
            ConsultationProposalSchedule.self,
            from: Data(json.utf8),
        )
    }

    // MARK: - Silent by default

    @Test func saysNothingWhenThereIsNothingToSay() throws {
        let schedule = try decodeSchedule("""
        {"endsAt":"\(Self.endsAtUtc)","durationMinutes":120,"bufferMinutes":10,
         "timeZone":"America/Los_Angeles","outlook":"WITHIN_WORKING_HOURS"}
        """)

        #expect(schedule.notice == nil)
    }

    /// The appointment was already running late before this proposal existed.
    /// Blaming the proposal for that is a false alarm — the same mistake F2
    /// caught itself about to make with calendar blocks.
    @Test func staysSilentOnAPreExistingAfterHoursAppointment() throws {
        let schedule = try decodeSchedule("""
        {"endsAt":"\(Self.endsAtUtc)","timeZone":"America/Los_Angeles",
         "outlook":"ALREADY_OUTSIDE_WORKING_HOURS"}
        """)

        #expect(schedule.notice == nil)
    }

    @Test func staysSilentWhenTheLocationHasNoWorkingHours() throws {
        let schedule = try decodeSchedule("""
        {"endsAt":"\(Self.endsAtUtc)","timeZone":"America/Los_Angeles",
         "outlook":"WORKING_HOURS_MISSING"}
        """)

        #expect(schedule.notice == nil)
    }

    // MARK: - The one state that speaks

    @Test func tellsTheProWhenTheseServicesRunPastClosing() throws {
        let schedule = try decodeSchedule("""
        {"endsAt":"\(Self.endsAtUtc)","durationMinutes":120,"bufferMinutes":10,
         "timeZone":"America/Los_Angeles","outlook":"PAST_WORKING_HOURS"}
        """)

        #expect(
            schedule.notice
                == "Sent. With these services the appointment now runs to 6:15 PM — past your working hours."
        )
    }

    /// The end time belongs to the APPOINTMENT, not to the device. A pro in a
    /// different zone from the salon must not be shown a confident wrong clock,
    /// so the sentence drops the time rather than guessing at a zone.
    @Test func dropsTheClockWhenTheServerCouldNotResolveAZone() throws {
        let schedule = try decodeSchedule("""
        {"endsAt":"\(Self.endsAtUtc)","durationMinutes":120,"bufferMinutes":10,
         "timeZone":null,"outlook":"PAST_WORKING_HOURS"}
        """)

        #expect(
            schedule.notice
                == "Sent. With these services the appointment now runs past your working hours."
        )
    }

    // MARK: - Totality

    @Test func neverReportsAnUnansweredQuestionAsAnAnswer() throws {
        let schedule = try decodeSchedule("""
        {"endsAt":"\(Self.endsAtUtc)","timeZone":null,"outlook":"NOT_CHECKED"}
        """)

        #expect(schedule.outlook == .notChecked)
        #expect(schedule.notice == nil)
    }

    /// A server that grows a new state must not silence this build — an unknown
    /// value is "we did not get an answer", never "all clear".
    @Test func anUnknownOutlookDecodesToNotChecked() throws {
        let schedule = try decodeSchedule("""
        {"endsAt":"\(Self.endsAtUtc)","timeZone":"America/Los_Angeles",
         "outlook":"SOMETHING_THE_SERVER_LEARNED_LATER"}
        """)

        #expect(schedule.outlook == .notChecked)
        #expect(schedule.notice == nil)
    }

    /// An OLDER server sends no `schedule` at all. That must still decode.
    @Test func aProposalResponseWithNoScheduleStillDecodes() throws {
        struct Response: Decodable {
            let schedule: ConsultationProposalSchedule?
        }

        let response = try JSONDecoder().decode(
            Response.self,
            from: Data(#"{"approval":{"id":"a1"}}"#.utf8),
        )

        #expect(response.schedule == nil)
    }

    /// Every state is either explained or deliberately silent — no case may be
    /// left with no decision at all.
    @Test func everyStateIsEitherSilentOrExplained() {
        for outlook in ConsultationScheduleOutlook.allCases {
            let notice = outlook.notice(endsAtLabel: "6:15 PM")

            if outlook == .pastWorkingHours {
                #expect(notice?.contains("6:15 PM") == true, "\(outlook) must say something")
            } else {
                #expect(notice == nil, "\(outlook) must stay silent")
            }
        }
    }

    // MARK: - Wire.timeOnly

    @Test func timeOnlyRendersInTheGivenZoneNotTheDeviceZone() {
        #expect(Wire.timeOnly(Self.endsAtUtc, timeZone: "America/Los_Angeles") == "6:15 PM")
        #expect(Wire.timeOnly(Self.endsAtUtc, timeZone: "America/New_York") == "9:15 PM")
        #expect(Wire.timeOnly(Self.endsAtUtc, timeZone: "UTC") == "1:15 AM")
        #expect(Wire.timeOnly("not-a-date", timeZone: "UTC") == "")
    }
}
