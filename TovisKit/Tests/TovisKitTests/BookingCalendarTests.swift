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
        durationMinutes: Int = 90,
        location: String? = "Studio Nine, Portland",
        notes: String? = nil
    ) -> String {
        BookingCalendar.icsDocument(
            uid: "bk_1@tovis", title: title, start: start,
            durationMinutes: durationMinutes, location: location, notes: notes, now: now
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
}
