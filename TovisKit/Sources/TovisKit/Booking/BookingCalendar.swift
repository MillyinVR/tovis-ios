import Foundation

/// Builds an RFC 5545 iCalendar (`.ics`) document for a booking so the native
/// client can hand it to the share sheet ("Add to Calendar"). Mirrors web's
/// `GET /api/v1/calendar?bookingId=…` ICS download and `lib/calendar/bookingInvite.ts`.
///
/// Timezone correctness: a booking is a single, non-recurring appointment that
/// happens at the salon's physical location at a fixed local wall-clock time.
/// When a valid IANA `timeZone` is supplied we anchor the event to that zone —
/// emitting `DTSTART/DTEND` as floating local wall-clock times with a `TZID`
/// *and* a self-contained `VTIMEZONE` whose offset is the real (DST-aware) UTC
/// offset in effect at the booked instant. Without the `VTIMEZONE`, strict/older
/// calendar clients can't resolve the `TZID` and fall back to UTC, which is how
/// appointments end up saved at the wrong time. When no valid zone is supplied
/// we fall back to bare UTC (`…Z`) instants. Text fields are escaped per the
/// spec (backslash / semicolon / comma / newline).
public enum BookingCalendar {
    /// Compose the single-VEVENT document. `durationMinutes ≤ 0` yields a
    /// zero-length event (DTEND == DTSTART). Pass the booking's IANA `timeZone`
    /// (e.g. `America/New_York`) to pin the event to the salon's local time;
    /// nil/blank/invalid falls back to UTC `…Z` instants. `now` is injectable
    /// for tests.
    public static func icsDocument(
        uid: String,
        title: String,
        start: Date,
        durationMinutes: Int,
        location: String?,
        notes: String?,
        timeZone: String? = nil,
        now: Date = Date()
    ) -> String {
        let end = start.addingTimeInterval(TimeInterval(max(0, durationMinutes) * 60))

        // Resolve a valid IANA zone; nil/blank/unrecognized → UTC fallback.
        let zone: TimeZone? = {
            guard let raw = timeZone?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return TimeZone(identifier: raw)
        }()

        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Tovis//Booking//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
        ]

        // A self-contained VTIMEZONE so the referenced TZID always resolves,
        // even offline / on strict clients. Anchored on the start instant.
        if let zone {
            lines.append(contentsOf: vtimeZone(zone, at: start))
        }

        lines.append("BEGIN:VEVENT")
        lines.append("UID:\(escape(uid))")
        lines.append("DTSTAMP:\(utcStamp(now))")

        if let zone {
            let tzid = escape(zone.identifier)
            lines.append("DTSTART;TZID=\(tzid):\(localStamp(start, in: zone))")
            lines.append("DTEND;TZID=\(tzid):\(localStamp(end, in: zone))")
        } else {
            lines.append("DTSTART:\(utcStamp(start))")
            lines.append("DTEND:\(utcStamp(end))")
        }

        lines.append("SUMMARY:\(escape(title))")

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

    /// A minimal self-contained VTIMEZONE for a single, non-recurring
    /// appointment: one STANDARD sub-component (no RRULE) carrying the real
    /// offset at the booked instant defines the TZID for every referenced time.
    /// Mirrors web's `buildVTimeZone`. We anchor on the start offset; an
    /// appointment that literally straddles a DST transition — extraordinarily
    /// rare given normal durations — would render its end an hour off, which we
    /// accept over the complexity of a full transition table.
    private static func vtimeZone(_ zone: TimeZone, at instant: Date) -> [String] {
        let offset = utcOffset(zone, at: instant)
        return [
            "BEGIN:VTIMEZONE",
            "TZID:\(escape(zone.identifier))",
            "BEGIN:STANDARD",
            "DTSTART:19700101T000000",
            "TZOFFSETFROM:\(offset)",
            "TZOFFSETTO:\(offset)",
            "END:STANDARD",
            "END:VTIMEZONE",
        ]
    }

    /// ICS UTC-offset string (`±HHMM`) in effect at `instant` for `zone`.
    /// Foundation's `secondsFromGMT(for:)` is already `local − UTC` and DST
    /// aware — exactly the ICS TZOFFSET sign convention (west of UTC negative).
    private static func utcOffset(_ zone: TimeZone, at instant: Date) -> String {
        let seconds = zone.secondsFromGMT(for: instant)
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        return String(format: "%@%02d%02d", sign, magnitude / 3600, (magnitude % 3600) / 60)
    }

    /// UTC basic-format timestamp: `yyyyMMdd'T'HHmmss'Z'`. Built locally (not a
    /// shared static) to stay clear of cross-actor `DateFormatter` sharing.
    private static func utcStamp(_ date: Date) -> String {
        stamp(date, in: TimeZone(identifier: "UTC"), format: "yyyyMMdd'T'HHmmss'Z'")
    }

    /// Basic-format local wall-clock (`yyyyMMdd'T'HHmmss`, no trailing `Z`) in
    /// `zone` — the floating time referenced by a `TZID`.
    private static func localStamp(_ date: Date, in zone: TimeZone) -> String {
        stamp(date, in: zone, format: "yyyyMMdd'T'HHmmss")
    }

    private static func stamp(_ date: Date, in zone: TimeZone?, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = format
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
