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

    // MARK: - Client confirmation (K13)

    /// `fullBooking` plus a confirmation state — the shape the live feed sends
    /// once the pro's reminder has asked.
    private func withConfirmation(_ kind: String, label: String, description: String,
                                  tone: String) -> String {
        fullBooking.replacingOccurrences(
            of: "\"serviceSwatch\": \"09\",",
            with: """
            "serviceSwatch": "09",
            "clientConfirmation": {
              "kind": "\(kind)", "label": "\(label)",
              "description": "\(description)", "tone": "\(tone)", "significant": true
            },
            """)
    }

    @Test("🔴 the confirmation GLYPH always has spoken words behind it")
    func confirmationIsSpokenNotJustDrawn() throws {
        // The exact K9-A failure, one channel later: on the tile this state is a
        // bare SHAPE in the corner. If the words ever leave this string the
        // channel simply does not exist for a VoiceOver user.
        let decoded = try event(withConfirmation(
            "AWAITING_CLIENT", label: "Awaiting client",
            description: "Awaiting client confirmation", tone: "pending"))
        #expect(decoded.clientConfirmationDisplay != nil)

        let label = proCalendarTileAccessibilityLabel(
            event: decoded, timeLabel: "9:15 AM", locationLabel: "TOVIS Test Salon",
            conflict: false)

        // After the money, before the place — web's aria label reads in this
        // same order.
        #expect(label == "Test Client, 9:15 AM, Balayage, New client · requested you, Deposit paid $40.00, Awaiting client confirmation, TOVIS Test Salon")
    }

    @Test("the spoken state is the DESCRIPTION, never the bare pill label")
    func confirmationSpeaksTheSentenceNotTheLabel() throws {
        // 🔴 "Client confirmed" read aloud beside a status that B10 renders as
        // "Confirmed" is two facts wearing one word. The description is a whole
        // sentence for exactly that reason.
        let label = proCalendarTileAccessibilityLabel(
            event: try event(withConfirmation(
                "CLIENT_CONFIRMED", label: "Client confirmed",
                description: "Client confirmed this appointment", tone: "success")),
            timeLabel: "9:15 AM", locationLabel: nil, conflict: false)

        #expect(label.contains("Client confirmed this appointment"))
    }

    @Test("a booking nobody asked about says nothing about confirmation")
    func noAskIsSilent() throws {
        // The common case: web omits the key entirely, and the label must be
        // byte-identical to what it was before K13.
        let label = proCalendarTileAccessibilityLabel(
            event: try event(fullBooking), timeLabel: "9:15 AM",
            locationLabel: nil, conflict: false)

        #expect(label == "Test Client, 9:15 AM, Balayage, New client · requested you, Deposit paid $40.00")
        #expect(!label.lowercased().contains("confirm"))
    }

    @Test("each state gets its OWN shape, not just its own colour")
    func glyphsDifferByShape() {
        // Colour already belongs to the service stripe and the status fill, so
        // the three answers have to separate for a pro who can't tell the tones
        // apart. Distinct symbols, and the two ANSWERS are filled discs while
        // the open question is a hollow ring — readable in greyscale.
        #expect(confirmationGlyphName(.clientConfirmed) == "checkmark.circle.fill")
        #expect(confirmationGlyphName(.declined) == "xmark.circle.fill")
        #expect(confirmationGlyphName(.awaitingClient) == "questionmark.circle")

        let all = ProClientConfirmation.State.allCases.map(confirmationGlyphName)
        #expect(Set(all).count == 3, "answered/declined/asked must not share a shape")
    }

    @Test("the client card's local tone cannot drift from the wire's")
    func localToneMatchesTheWireTable() {
        // The pro surfaces paint the tone the SERVER sent (`wireBadgeTone`); the
        // client's answer card has only a bare state to work from, because the
        // answer route echoes a state and not a badge. Two tables for one set of
        // meanings is how a "confirmed" green becomes two different greens — so
        // the local one is DERIVED from the wire one, and this pins it.
        #expect(confirmationTone(.clientConfirmed) == wireBadgeTone("success"))
        #expect(confirmationTone(.declined) == wireBadgeTone("danger"))
        #expect(confirmationTone(.awaitingClient) == wireBadgeTone("pending"))

        // And the three are actually distinct — a table that returned one colour
        // for everything would pass the equalities above.
        let tones = [ProClientConfirmation.State.clientConfirmed, .declined, .awaitingClient]
            .map(confirmationTone)
        #expect(Set(tones.map(String.init(describing:))).count == 3)
    }

    // MARK: - Unsigned consent (K15 / K17-A)

    /// `fullBooking` plus the unsigned-consent mark — the shape the live route
    /// sends once a pro binds a form to one of the booking's services.
    private var withConsentRequirement: String {
        fullBooking.replacingOccurrences(
            of: "\"serviceSwatch\": \"09\",",
            with: """
            "serviceSwatch": "09",
            "consentRequirement": {
              "kind": "UNSIGNED_CONSENT", "label": "Form due",
              "description": "K17 drive release not signed",
              "tone": "warn", "significant": true
            },
            """)
    }

    @Test("🔴 the chip prints an abbreviation — the spoken name says WHICH form")
    func consentNamesTheFormNotJustTheChip() throws {
        // "Form due" is the same three words on every tile. A pro chasing a
        // signature needs the form's name, and on a phone's ~45pt week column
        // the chip isn't drawn at all — so this string is the only carrier
        // there, exactly as it is for the service (K9-A) and the confirmation
        // glyph (K13).
        let decoded = try event(withConsentRequirement)
        #expect(decoded.consentRequirementDisplay?.label == "Form due")

        let label = proCalendarTileAccessibilityLabel(
            event: decoded, timeLabel: "9:15 AM", locationLabel: "TOVIS Test Salon",
            conflict: false)

        // After the confirmation, before the place — web's aria label reads in
        // this same order.
        #expect(label == "Test Client, 9:15 AM, Balayage, New client · requested you, Deposit paid $40.00, K17 drive release not signed, TOVIS Test Salon")
        #expect(!label.contains("Form due"))
    }

    @Test("an appointment that already started warns nobody")
    func insignificantConsentIsSilent() throws {
        // The web helper sets `significant: false` once `scheduledFor <= now`,
        // so a pro binding their first form today doesn't light up their whole
        // history in amber. The device honours that call and never re-derives it.
        let row = withConsentRequirement.replacingOccurrences(
            of: #""tone": "warn", "significant": true"#,
            with: #""tone": "warn", "significant": false"#)
        let label = proCalendarTileAccessibilityLabel(
            event: try event(row), timeLabel: "9:15 AM", locationLabel: nil, conflict: false)

        #expect(!label.contains("not signed"))
        #expect(label == "Test Client, 9:15 AM, Balayage, New client · requested you, Deposit paid $40.00")
    }

    @Test("a booking with nothing outstanding reads exactly as it did before K17")
    func noRequirementIsByteIdentical() throws {
        // The common case — every booking until a pro binds a form.
        let label = proCalendarTileAccessibilityLabel(
            event: try event(fullBooking), timeLabel: "9:15 AM",
            locationLabel: nil, conflict: false)
        #expect(!label.lowercased().contains("signed"))
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
