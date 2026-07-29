import Foundation
import Testing
@testable import TovisKit

// K2: the payment badge is consumed VERBATIM off the wire (derived by web's ONE
// helper, lib/booking/paymentBadge.ts) — these tests pin the two device-side
// duties: render exactly what the wire says, and NEVER let a malformed or
// future badge crash the whole calendar/list decode (it hides instead, the
// mirror of web's kind-validated parsePaymentBadgeWire).

struct PaymentBadgeTests {

    private func badge(_ json: String) throws -> ProPaymentBadge {
        try JSONDecoder().decode(ProPaymentBadge.self, from: Data(json.utf8))
    }

    @Test func rendersAWireBadgeVerbatim() throws {
        let display = try #require(badge(
            #"{"kind":"DEPOSIT_PAID","label":"Deposit paid $40.00","tone":"info","significant":true}"#
        ).display)
        #expect(display.kind == "DEPOSIT_PAID")
        #expect(display.label == "Deposit paid $40.00")
        #expect(display.tone == "info")
        #expect(display.significant)
    }

    @Test func aDisputedBadgeKeepsItsDangerToneAndWarningLabel() throws {
        // The M11 honesty rule surfaced on device: a disputed booking renders
        // danger, never a clean "Paid".
        let display = try #require(badge(
            #"{"kind":"DISPUTED","label":"⚠ Disputed","tone":"danger","significant":true}"#
        ).display)
        #expect(display.label == "⚠ Disputed")
        #expect(display.tone == "danger")
    }

    @Test func everyKnownKindIsRenderable() throws {
        for kind in ProPaymentBadge.knownKinds {
            let display = try #require(
                badge(#"{"kind":"\#(kind)","label":"x","tone":"neutral","significant":true}"#).display,
                "kind \(kind) should render")
            #expect(display.kind == kind)
        }
    }

    @Test func anUnknownFutureKindHidesInsteadOfRendering() throws {
        // A future web release may ship a kind this build doesn't know. The chip
        // hides (display == nil); decoding must not throw.
        let parsed = try badge(
            #"{"kind":"STORE_CREDIT","label":"Store credit","tone":"info","significant":true}"#)
        #expect(parsed.display == nil)
    }

    @Test func aBlankLabelHidesTheChip() throws {
        // The label is server-composed and never rebuilt on device — without it
        // there is nothing truthful to show.
        #expect(try badge(#"{"kind":"PAID","label":"  ","tone":"success"}"#).display == nil)
        #expect(try badge(#"{"kind":"PAID","tone":"success"}"#).display == nil)
    }

    @Test func missingToneAndSignificanceGetSafeDefaults() throws {
        let display = try #require(badge(#"{"kind":"PAID","label":"Paid"}"#).display)
        #expect(display.tone == "neutral")
        #expect(display.significant)
    }

    @Test func aMalformedBadgeNeverFailsTheParentDecode() throws {
        // The badge value is a STRING here, not an object — the event must still
        // decode (one bad badge must not blank the whole calendar).
        let event = try JSONDecoder().decode(ProCalendarEvent.self, from: Data("""
        {
          "id": "bk_1", "kind": "BOOKING",
          "startsAt": "2026-07-29T17:00:00.000Z", "endsAt": "2026-07-29T18:00:00.000Z",
          "title": "Balayage", "clientName": "Jordan Rivera", "status": "ACCEPTED",
          "durationMinutes": 60, "localDateKey": "2026-07-29",
          "paymentBadge": "DEPOSIT_PAID"
        }
        """.utf8))
        #expect(event.paymentBadge?.display == nil)

        // Wrong-typed subfields degrade the same way.
        #expect(try badge(#"{"kind":42,"label":true}"#).display == nil)
    }

    @Test func aCalendarBookingEventCarriesTheBadge() throws {
        let event = try JSONDecoder().decode(ProCalendarEvent.self, from: Data("""
        {
          "id": "bk_2", "kind": "BOOKING",
          "startsAt": "2026-07-29T17:00:00.000Z", "endsAt": "2026-07-29T18:00:00.000Z",
          "title": "Full Color", "clientName": "Priya Nadkarni", "status": "ACCEPTED",
          "durationMinutes": 60, "localDateKey": "2026-07-29",
          "paymentBadge": {"kind":"PREPAID_IN_FULL","label":"Prepaid in full","tone":"success","significant":true}
        }
        """.utf8))
        let display = try #require(event.paymentBadge?.display)
        #expect(display.label == "Prepaid in full")
        #expect(display.tone == "success")
    }

    @Test func blocksAndHoldsSimplyOmitTheBadge() throws {
        let block = try JSONDecoder().decode(ProCalendarEvent.self, from: Data("""
        {
          "id": "block:bl_1", "blockId": "bl_1", "kind": "BLOCK",
          "startsAt": "2026-07-29T17:00:00.000Z", "endsAt": "2026-07-29T18:00:00.000Z",
          "title": "Lunch", "clientName": "", "status": "BLOCKED",
          "durationMinutes": 60, "localDateKey": "2026-07-29"
        }
        """.utf8))
        #expect(block.paymentBadge == nil)
    }
}
