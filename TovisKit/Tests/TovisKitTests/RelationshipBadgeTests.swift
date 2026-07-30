import Foundation
import Testing
@testable import TovisKit

// K6: the NR/NNR/RR/RNR mark is consumed VERBATIM off the wire (a per-booking
// SNAPSHOT derived by web's ONE helper, lib/booking/relationshipLabel.ts).
// These pin the two device-side duties: render exactly what the wire says, and
// NEVER let a malformed or future mark crash the whole calendar/list/chart
// decode (it hides instead, the mirror of web's kind-validated
// parseRelationshipBadgeWire).

struct RelationshipBadgeTests {

    private func badge(_ json: String) throws -> ProRelationshipBadge {
        try JSONDecoder().decode(ProRelationshipBadge.self, from: Data(json.utf8))
    }

    @Test func rendersAWireMarkVerbatim() throws {
        let display = try #require(badge(
            #"{"kind":"NR","label":"NR","description":"New client · requested you","tone":"accent","significant":true}"#
        ).display)
        #expect(display.kind == "NR")
        #expect(display.label == "NR")
        #expect(display.description == "New client · requested you")
        #expect(display.tone == "accent")
        #expect(display.significant)
    }

    @Test func rnrIsARealFourthMark() throws {
        // Decision D1: a returning client who arrived via discovery is its own
        // cell, not RR. A build that didn't know RNR would hide the chip.
        let display = try #require(badge(
            #"{"kind":"RNR","label":"RNR","description":"Returning client · via discovery","tone":"info","significant":true}"#
        ).display)
        #expect(display.label == "RNR")
        #expect(display.description == "Returning client · via discovery")
    }

    @Test func everyKnownKindIsRenderable() throws {
        for kind in ProRelationshipBadge.knownKinds {
            let display = try #require(
                badge(#"{"kind":"\#(kind)","label":"x","description":"y","tone":"neutral","significant":true}"#).display,
                "kind \(kind) should render")
            #expect(display.kind == kind)
        }
    }

    @Test func unknownArrivesInsignificantSoNothingRenders() throws {
        // UNKNOWN decodes fine — it is a first-class value, not an error — but
        // the wire marks it insignificant and every surface must then show
        // NOTHING. Absence is the honest display for unclassified history; a pro
        // importing a book of regulars must not open the app to a wall of marks.
        let display = try #require(badge(
            #"{"kind":"UNKNOWN","label":"Unknown","description":"Not classified","tone":"neutral","significant":false}"#
        ).display)
        #expect(display.significant == false)
    }

    @Test func anUnknownFutureKindHidesInsteadOfRendering() throws {
        let parsed = try badge(
            #"{"kind":"VIP","label":"VIP","description":"A future mark","tone":"accent","significant":true}"#)
        #expect(parsed.display == nil)
    }

    @Test func aBlankLabelHidesTheChip() throws {
        #expect(try badge(#"{"kind":"NR","label":"  ","tone":"accent"}"#).display == nil)
        #expect(try badge(#"{"kind":"NR","tone":"accent"}"#).display == nil)
    }

    @Test func aMissingDescriptionFallsBackToTheMarkNeverToSilence() throws {
        // The description is what VoiceOver speaks. If it ever arrives blank the
        // chip still renders and still has SOMETHING to announce — an empty
        // accessibility label is worse than bare letters.
        let display = try #require(badge(#"{"kind":"RR","label":"RR","tone":"neutral"}"#).display)
        #expect(display.description == "RR")
        #expect(display.tone == "neutral")
        #expect(display.significant)
    }

    @Test func aMalformedMarkNeverFailsTheParentDecode() throws {
        // The badge value is a STRING here, not an object — the event must still
        // decode (one bad mark must not blank the whole calendar).
        let event = try JSONDecoder().decode(ProCalendarEvent.self, from: Data("""
        {
          "id": "bk_1", "kind": "BOOKING",
          "startsAt": "2026-07-29T17:00:00.000Z", "endsAt": "2026-07-29T18:00:00.000Z",
          "title": "Balayage", "clientName": "Jordan Rivera", "status": "ACCEPTED",
          "durationMinutes": 60, "localDateKey": "2026-07-29",
          "relationshipBadge": "NR"
        }
        """.utf8))
        #expect(event.relationshipBadge?.display == nil)

        #expect(try badge(#"{"kind":42,"label":true}"#).display == nil)
    }

    @Test func aCalendarBookingEventCarriesTheMark() throws {
        let event = try JSONDecoder().decode(ProCalendarEvent.self, from: Data("""
        {
          "id": "bk_2", "kind": "BOOKING",
          "startsAt": "2026-07-29T17:00:00.000Z", "endsAt": "2026-07-29T18:00:00.000Z",
          "title": "Full Color", "clientName": "Priya Nadkarni", "status": "ACCEPTED",
          "durationMinutes": 60, "localDateKey": "2026-07-29",
          "relationshipBadge": {"kind":"RR","label":"RR","description":"Returning client · requested you","tone":"neutral","significant":true}
        }
        """.utf8))
        let display = try #require(event.relationshipBadge?.display)
        #expect(display.label == "RR")
        #expect(display.tone == "neutral")
    }

    @Test func anAbsentFieldDecodesFineOnEverySurface() throws {
        // A server that predates web #797/#798 sends no field at all. Every
        // consumer must decode and simply show nothing.
        let block = try JSONDecoder().decode(ProCalendarEvent.self, from: Data("""
        {
          "id": "block:bl_1", "blockId": "bl_1", "kind": "BLOCK",
          "startsAt": "2026-07-29T17:00:00.000Z", "endsAt": "2026-07-29T18:00:00.000Z",
          "title": "Lunch", "clientName": "", "status": "BLOCKED",
          "durationMinutes": 60, "localDateKey": "2026-07-29"
        }
        """.utf8))
        #expect(block.relationshipBadge == nil)

        let chartRow = try JSONDecoder().decode(ProChartBooking.self, from: Data("""
        {
          "id": "bk_3", "status": "COMPLETED",
          "scheduledFor": "2026-07-15T18:00:00.000Z", "timeZone": "America/Los_Angeles",
          "serviceName": "Cut", "categoryName": "Hair", "proName": "Other Pro",
          "isMine": false, "total": "80.00", "aftercareNotes": null
        }
        """.utf8))
        #expect(chartRow.relationshipBadge == nil)
    }

    @Test func anotherProsChartRowCarriesNoMark() throws {
        // The server sends the mark ONLY on the viewing pro's own rows. This
        // pins the shape the device is built against: isMine false ⇒ null.
        let row = try JSONDecoder().decode(ProChartBooking.self, from: Data("""
        {
          "id": "bk_4", "status": "COMPLETED",
          "scheduledFor": "2026-07-15T18:00:00.000Z", "timeZone": "America/Los_Angeles",
          "serviceName": "Cut", "categoryName": "Hair", "proName": "Other Pro (K6 seed)",
          "isMine": false, "total": "80.00", "aftercareNotes": null,
          "relationshipBadge": null
        }
        """.utf8))
        #expect(row.isMine == false)
        #expect(row.relationshipBadge?.display == nil)
    }
}
