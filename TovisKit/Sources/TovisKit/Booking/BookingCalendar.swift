import Foundation

/// Builds an RFC 5545 iCalendar (`.ics`) document for a booking so the native
/// client can hand it to the share sheet ("Add to Calendar"). Mirrors web's
/// `GET /api/v1/calendar?bookingId=…` ICS download.
///
/// Instants are emitted in UTC (`…Z`); calendar apps render them in the
/// viewer's local zone, which keeps the wall-clock correct for the same
/// instant regardless of the salon's zone. Text fields are escaped per the
/// spec (backslash / semicolon / comma / newline).
public enum BookingCalendar {
    /// Compose the single-VEVENT document. `durationMinutes ≤ 0` yields a
    /// zero-length event (DTEND == DTSTART). `now` is injectable for tests.
    public static func icsDocument(
        uid: String,
        title: String,
        start: Date,
        durationMinutes: Int,
        location: String?,
        notes: String?,
        now: Date = Date()
    ) -> String {
        let end = start.addingTimeInterval(TimeInterval(max(0, durationMinutes) * 60))

        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Tovis//Booking//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "BEGIN:VEVENT",
            "UID:\(escape(uid))",
            "DTSTAMP:\(stamp(now))",
            "DTSTART:\(stamp(start))",
            "DTEND:\(stamp(end))",
            "SUMMARY:\(escape(title))",
        ]

        if let location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("LOCATION:\(escape(location))")
        }
        if let notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("DESCRIPTION:\(escape(notes))")
        }

        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")

        // RFC 5545 requires CRLF line breaks and a trailing terminator.
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// UTC basic-format timestamp: `yyyyMMdd'T'HHmmss'Z'`. Built locally (not a
    /// shared static) to stay clear of cross-actor `DateFormatter` sharing.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// RFC 5545 TEXT escaping. Backslash first so later escapes aren't
    /// double-escaped; all newline variants collapse to the literal `\n`.
    private static func escape(_ raw: String) -> String {
        var out = raw.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: ";", with: "\\;")
        out = out.replacingOccurrences(of: ",", with: "\\,")
        out = out.replacingOccurrences(of: "\r\n", with: "\\n")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        out = out.replacingOccurrences(of: "\r", with: "\\n")
        return out
    }
}
