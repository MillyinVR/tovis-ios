import Foundation
import Testing
@testable import TovisKit

// `Wire.bookingZone` — the zone a free wall-clock entry is INTERPRETED in when a
// pro types a custom appointment time (ProNewBookingView / ProRescheduleView).
//
// This is not a display concern, which is why it does not share `Wire.dateTime`'s
// `?? .current` fallback: the wall time the pro types is turned into an absolute
// instant, so the zone chosen here decides WHICH MOMENT gets booked. Falling back
// to the device zone means a travelling pro's "2:00 PM" books a different moment
// than the same entry made on web, where `NewBookingForm` resolves the same field
// with `datetimeLocalToUtcIsoStrict(scheduledAt, bookingTimeZone)` and
// `bookingTimeZone` is `isValidIanaTimeZone(location.timeZone) ? tz : 'UTC'`.
// These cases pin that contract.
//
// Two things were checked against the real implementations rather than assumed:
//   • `PST` / `EST` are VALID to both Node's ICU (`Intl.DateTimeFormat`) and
//     Darwin's `TimeZone(identifier:)`, and Darwin gives `PST` the -7 August
//     offset ICU does — so they are not fallback cases on either platform.
//   • Darwin canonicalizes the identifier `UTC` to `GMT`. Same zero-offset,
//     no-DST zone web means by 'UTC'; the identifier string is what differs, and
//     it is what the picker's caption shows.
struct BookingWallClockZoneTests {
    @Test("a valid IANA identifier is used as-is")
    func validIdentifierWins() {
        #expect(Wire.bookingZone("America/Los_Angeles").identifier == "America/Los_Angeles")
        #expect(Wire.bookingZone("America/New_York").identifier == "America/New_York")
        #expect(Wire.bookingZone("Europe/London").identifier == "Europe/London")
    }

    // ALLOW cases: zone identifiers that are not `Region/City` but that both
    // platforms accept. Rejecting these would be an iOS-only refusal, and would
    // send the booking to UTC where web sends it to the real zone.
    @Test("legacy aliases both platforms accept are honored, not fallen back")
    func legacyAliasesAreHonored() {
        #expect(Wire.bookingZone("PST").identifier == "PST")
        #expect(Wire.bookingZone("EST").identifier == "EST")
        #expect(Wire.bookingZone("GMT").identifier == "GMT")
    }

    // The server's own `cleanIana` (lib/booking/timeZoneTruth.ts) trims before
    // validating, and the location write path trims on the way in (`pickString`),
    // so a padded value should resolve to the zone the SERVER would resolve it to.
    @Test("surrounding whitespace does not defeat a real zone")
    func trimsBeforeResolving() {
        #expect(Wire.bookingZone("  America/Chicago  ").identifier == "America/Chicago")
    }

    // The shapes that reach here when a location has no usable zone. Each must
    // land on zero-offset UTC — never the device zone — so the instant iOS
    // computes matches the one web computes from the same entry.
    @Test("nil / blank / unrecognized fall back to UTC, not the device zone")
    func fallsBackToUTC() {
        for raw in [nil, "", "   ", "Not/AZone", "Mars/Olympus_Mons"] {
            let zone = Wire.bookingZone(raw)
            #expect(zone.secondsFromGMT(for: Date()) == 0)
            #expect(zone.identifier == "GMT") // Darwin's canonical spelling of UTC
        }
    }

    // The bug this exists to stop: the same typed wall time must produce the SAME
    // instant regardless of where the pro's device is. The picker is pinned to the
    // booking zone, so the device zone is not part of the answer.
    @Test("a wall time resolves to the booking zone's instant, not the device's")
    func wallTimeIsDeviceIndependent() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 12
        components.hour = 14
        components.minute = 0

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Wire.bookingZone("America/Los_Angeles")
        let booked = calendar.date(from: components)

        // 14:00 PDT on 2026-08-12 is 21:00Z — whatever the device is set to.
        #expect(booked.map(ProCalendarGrid.iso) == "2026-08-12T21:00:00Z")

        // The same components read in the device's zone are only the same instant
        // by coincidence of where this test runs; that coincidence is the bug.
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        #expect(deviceCalendar.date(from: components) != booked)
    }
}
