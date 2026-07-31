import Foundation
import Testing
import TovisKit
@testable import Tovis

// What VoiceOver reads for one pro-calendar tile.
//
// 🔴 Why this suite exists: K9 gave the tile a SERVICE colour, and a colour is
// the one signal a screenshot proves and a screen reader cannot hear. Web has
// always printed the service as the card's secondary line and carried it in the
// aria label; the iOS tile has room for a single line and spends it on the
// client, so before K9 the service appeared NOWHERE on the tile — and K9 then
// encoded it as a hue. A channel only sighted users can read, with no textual
// equivalent anywhere, is decoration pretending to be data.
//
// The other reason nothing here is gated on tile density: a phone's week column
// is ~45pt and fits none of the chips, so the visual surface silently drops
// signals that this string must keep.
@Suite struct ProCalendarTileAccessibilityTests {

    private func event(_ json: String) throws -> ProCalendarEvent {
        try JSONDecoder().decode(ProCalendarEvent.self, from: Data(json.utf8))
    }

    /// A coloured booking carrying every badge — the shape the live feed sends.
    private let fullBooking = """
    {
      "id": "cmrr6vdjg0033po3nn4o0s6dv",
      "kind": "BOOKING",
      "startsAt": "2026-07-29T16:15:00.000Z",
      "endsAt": "2026-07-29T17:00:00.000Z",
      "title": "Balayage",
      "clientName": "Test Client",
      "status": "ACCEPTED",
      "locationType": "SALON",
      "locationId": "cmrbry47t000fpo0dz0kdy80z",
      "durationMinutes": 30,
      "localDateKey": "2026-07-29",
      "serviceSwatch": "09",
      "relationshipBadge": {
        "kind": "NR", "label": "NR",
        "description": "New client · requested you",
        "tone": "accent", "significant": true
      },
      "paymentBadge": {
        "kind": "DEPOSIT_PAID", "label": "Deposit paid $40.00",
        "tone": "info", "significant": true
      }
    }
    """

    @Test("the spoken name carries client, time, SERVICE, mark, money and place")
    func fullBookingLabel() throws {
        let label = proCalendarTileAccessibilityLabel(
            event: try event(fullBooking),
            timeLabel: "9:15 AM",
            locationLabel: "TOVIS Test Salon",
            conflict: false
        )

        #expect(label == "Test Client, 9:15 AM, Balayage, New client · requested you, Deposit paid $40.00, TOVIS Test Salon")
    }

    @Test("🔴 a booking with a service COLOUR always names that service in words")
    func swatchNeverTravelsAlone() throws {
        // The regression this suite exists for. If the service ever leaves the
        // spoken label, the swatch becomes the only carrier of "which service
        // is this" — and it is inaudible.
        let decoded = try event(fullBooking)
        #expect(decoded.serviceSwatchId == "09")

        let label = proCalendarTileAccessibilityLabel(
            event: decoded, timeLabel: "9:15 AM", locationLabel: nil, conflict: false)

        #expect(label.contains("Balayage"))
    }

    @Test("an UNCOLOURED booking names its service too")
    func uncolouredBookingStillNamesService() throws {
        // The service is not a consolation prize for having a colour — most
        // bookings have none, and they are exactly the ones whose stripe says
        // nothing at all.
        let row = fullBooking.replacingOccurrences(of: "\"serviceSwatch\": \"09\",", with: "")
        let decoded = try event(row)

        #expect(decoded.serviceSwatchId == nil)
        let label = proCalendarTileAccessibilityLabel(
            event: decoded, timeLabel: "9:15 AM", locationLabel: nil, conflict: false)
        #expect(label == "Test Client, 9:15 AM, Balayage, New client · requested you, Deposit paid $40.00")
    }

    @Test("an insignificant mark is silent, and does not take the service with it")
    func unknownRelationshipIsSilent() throws {
        let row = fullBooking
            .replacingOccurrences(of: "\"kind\": \"NR\", \"label\": \"NR\"",
                                  with: "\"kind\": \"UNKNOWN\", \"label\": \"—\"")
            .replacingOccurrences(of: "\"tone\": \"accent\", \"significant\": true",
                                  with: "\"tone\": \"neutral\", \"significant\": false")

        let label = proCalendarTileAccessibilityLabel(
            event: try event(row), timeLabel: "9:15 AM", locationLabel: nil, conflict: false)

        #expect(!label.contains("—"))
        #expect(label == "Test Client, 9:15 AM, Balayage, Deposit paid $40.00")
    }

    @Test("a conflict is spoken last, after everything that identifies the tile")
    func conflictComesLast() throws {
        let label = proCalendarTileAccessibilityLabel(
            event: try event(fullBooking), timeLabel: "9:15 AM",
            locationLabel: "TOVIS Test Salon", conflict: true)

        #expect(label.hasSuffix(", overlaps another appointment"))
    }

    @Test("a BLOCK is the pro's own time — no service, no mark, no money")
    func blockLabel() throws {
        let row = """
        {
          "id": "block:abc", "blockId": "abc", "kind": "BLOCK",
          "startsAt": "2026-07-29T18:00:00.000Z", "endsAt": "2026-07-29T19:00:00.000Z",
          "title": "Lunch", "clientName": "", "status": "BLOCKED",
          "durationMinutes": 60, "localDateKey": "2026-07-29"
        }
        """
        let label = proCalendarTileAccessibilityLabel(
            event: try event(row), timeLabel: "11:00 AM", locationLabel: nil, conflict: false)

        #expect(label == "Lunch, 11:00 AM")
    }

    @Test("a HOLD names nobody — it says only that the time is spoken for")
    func holdLabel() throws {
        // B5: a hold is deliberately anonymous server-side. Its `title` is the
        // fixed label, and it must NOT be read as a service the way a booking's
        // title is.
        let row = """
        {
          "id": "hold:xyz", "kind": "HOLD",
          "startsAt": "2026-07-29T22:00:00.000Z", "endsAt": "2026-07-29T23:15:00.000Z",
          "title": "Booking in progress", "clientName": "Held", "status": "HELD",
          "locationId": "cmrbry47t000fpo0dz0kdy80z",
          "durationMinutes": 75, "localDateKey": "2026-07-29"
        }
        """
        let label = proCalendarTileAccessibilityLabel(
            event: try event(row), timeLabel: "3:00 PM",
            locationLabel: "TOVIS Test Salon", conflict: false)

        #expect(label == "Booking in progress, 3:00 PM, TOVIS Test Salon")
        #expect(!label.contains("Held"))
    }

    @Test("a blank service title adds nothing rather than an empty gap")
    func blankServiceTitle() throws {
        let row = fullBooking.replacingOccurrences(of: "\"title\": \"Balayage\"",
                                                   with: "\"title\": \"   \"")
        let label = proCalendarTileAccessibilityLabel(
            event: try event(row), timeLabel: "9:15 AM", locationLabel: nil, conflict: false)

        #expect(!label.contains(", ,"))
        #expect(label == "Test Client, 9:15 AM, New client · requested you, Deposit paid $40.00")
    }
}
