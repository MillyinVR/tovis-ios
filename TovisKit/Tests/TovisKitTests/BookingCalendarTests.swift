import Foundation
import Testing
@testable import TovisKit

// The pure ICS document builder behind the native client "Add to Calendar"
// affordance (BookingDetailView). Verified without a SwiftUI host.
struct BookingCalendarTests {
    /// A fixed instant so DTSTAMP/DTSTART/DTEND are deterministic.
    private let start = Date(timeIntervalSince1970: 1_783_000_800) // 2026-07-02T14:00:00Z
    private let now = Date(timeIntervalSince1970: 1_782_000_000)

    private func ics(
        title: String = "Balayage",
        start: Date? = nil,
        durationMinutes: Int = 90,
        location: String? = "Studio Nine, Portland",
        notes: String? = nil,
        timeZone: String? = nil
    ) -> String {
        BookingCalendar.icsDocument(
            uid: "bk_1@tovis", title: title, start: start ?? self.start,
            durationMinutes: durationMinutes, location: location, notes: notes,
            timeZone: timeZone, now: now
        )
    }

    @Test func emitsWellFormedUtcVevent() {
        let doc = ics()
        // Envelope + CRLF line breaks + trailing terminator.
        #expect(doc.hasPrefix("BEGIN:VCALENDAR\r\n"))
        #expect(doc.hasSuffix("END:VCALENDAR\r\n"))
        #expect(doc.contains("\r\nBEGIN:VEVENT\r\n"))
        #expect(doc.contains("\r\nUID:bk_1@tovis\r\n"))
        #expect(doc.contains("\r\nSUMMARY:Balayage\r\n"))
        // UTC basic-format instants: start 14:00Z + 90 min → 15:30Z.
        #expect(doc.contains("\r\nDTSTART:20260702T140000Z\r\n"))
        #expect(doc.contains("\r\nDTEND:20260702T153000Z\r\n"))
    }

    @Test func includesLocationAndNotesWhenPresent() {
        let doc = ics(notes: "Bring a reference photo")
        #expect(doc.contains("\r\nLOCATION:Studio Nine\\, Portland\r\n")) // comma escaped
        #expect(doc.contains("\r\nDESCRIPTION:Bring a reference photo\r\n"))
    }

    @Test func omitsBlankLocationAndNotes() {
        let doc = ics(location: "   ", notes: nil)
        #expect(!doc.contains("LOCATION:"))
        #expect(!doc.contains("DESCRIPTION:"))
    }

    @Test func escapesSpecialCharactersInText() {
        let doc = ics(title: "Cut; color, style\nfull day")
        // backslash-escaped semicolon + comma, and newline collapsed to literal \n.
        #expect(doc.contains("SUMMARY:Cut\\; color\\, style\\nfull day"))
    }

    @Test func zeroOrNegativeDurationYieldsPointEvent() {
        let doc = ics(durationMinutes: 0)
        #expect(doc.contains("\r\nDTSTART:20260702T140000Z\r\n"))
        #expect(doc.contains("\r\nDTEND:20260702T140000Z\r\n"))

        let clamped = ics(durationMinutes: -30)
        #expect(clamped.contains("\r\nDTEND:20260702T140000Z\r\n"))
    }

    // MARK: - Timezone-anchored output (VTIMEZONE + TZID, DST aware)

    @Test func summerDstAnchorsToLocalWallClockWithVTimeZone() {
        // 2026-07-02T18:00:00Z == 2:00 PM in America/New_York (EDT, UTC−4).
        let summer = Date(timeIntervalSince1970: 1_783_015_200)
        let doc = ics(start: summer, timeZone: "America/New_York")

        // Self-contained VTIMEZONE carrying the real DST offset at the instant.
        #expect(doc.contains("\r\nBEGIN:VTIMEZONE\r\n"))
        #expect(doc.contains("\r\nTZID:America/New_York\r\n"))
        #expect(doc.contains("\r\nTZOFFSETFROM:-0400\r\n"))
        #expect(doc.contains("\r\nTZOFFSETTO:-0400\r\n"))
        #expect(doc.contains("\r\nEND:VTIMEZONE\r\n"))

        // Floating local wall-clock (no trailing Z): 2:00 PM start, +90 → 3:30 PM.
        #expect(doc.contains("\r\nDTSTART;TZID=America/New_York:20260702T140000\r\n"))
        #expect(doc.contains("\r\nDTEND;TZID=America/New_York:20260702T153000\r\n"))
        // No bare-UTC VEVENT instant when a zone is anchored (the VTIMEZONE's
        // own `DTSTART:19700101T000000` anchor is expected and left untouched).
        #expect(!doc.contains("\r\nDTSTART:20260702"))
        #expect(!doc.contains("20260702T140000Z"))
    }

    @Test func winterStandardTimeUsesNonDstOffset() {
        // 2026-01-02T19:00:00Z == 2:00 PM in America/New_York (EST, UTC−5).
        let winter = Date(timeIntervalSince1970: 1_767_380_400)
        let doc = ics(start: winter, timeZone: "America/New_York")

        #expect(doc.contains("\r\nTZOFFSETFROM:-0500\r\n"))
        #expect(doc.contains("\r\nTZOFFSETTO:-0500\r\n"))
        // Same 2:00 PM local wall-clock as the summer case, one offset lower.
        #expect(doc.contains("\r\nDTSTART;TZID=America/New_York:20260102T140000\r\n"))
        #expect(doc.contains("\r\nDTEND;TZID=America/New_York:20260102T153000\r\n"))
    }

    @Test func nilTimeZoneFallsBackToUtc() {
        let doc = ics(timeZone: nil)
        #expect(!doc.contains("BEGIN:VTIMEZONE"))
        #expect(!doc.contains("TZID="))
        #expect(doc.contains("\r\nDTSTART:20260702T140000Z\r\n"))
        #expect(doc.contains("\r\nDTEND:20260702T153000Z\r\n"))
    }

    @Test func invalidTimeZoneFallsBackToUtc() {
        let doc = ics(timeZone: "Not/AZone")
        #expect(!doc.contains("BEGIN:VTIMEZONE"))
        #expect(!doc.contains("TZID="))
        #expect(doc.contains("\r\nDTSTART:20260702T140000Z\r\n"))
    }
}
