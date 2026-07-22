import Foundation
import Testing
@testable import TovisKit

// Decode of a WAITLIST row from `GET /api/v1/pro/calendar`.
//
// The management sheet's "Offer a time" used to have only one thing to work with
// — `offerHref`, the deep-link that books the appointment outright — because
// those were the only waitlist keys the model decoded. The server has sent
// `waitlistEntryId` / `serviceId` / `offeringId` / `pendingOffer` all along
// (`toWaitlistEvent`, app/api/v1/pro/calendar/route.ts), which is what web's
// ManagementModal branches on to prefer the real offer flow. These cases pin
// that the iOS model now reads them.
//
// The JSON below is a VERBATIM capture of `management.waitlistToday[0]` from a
// live `GET /api/v1/pro/calendar?view=day`, driven against the local dev stack as
// the seeded pro — not a hand-built mock of the shape this model hopes for. A
// mock of the assumed shape passes while the real wire rots.
//
// One thing the capture shows that a mock would not have: `clientProfileId` is
// null (the chart-link gate withheld it) while `offerHref` still carries a
// clientId. The offer flow does not need either — the route derives the client
// from the entry — which is why `canOfferWaitlistTime` does not ask for them.
struct ProCalendarWaitlistEventTests {
    private func decode(_ json: String) throws -> ProCalendarEvent {
        try JSONDecoder().decode(ProCalendarEvent.self, from: Data(json.utf8))
    }

    /// A waitlist row with an active offering and no outstanding offer.
    private var offerableWaitlistRow: String {
        """
        {
          "id": "waitlist:cmrr3m7kl0003poai8vxy1mou",
          "kind": "BOOKING",
          "startsAt": "2026-07-19T01:09:55.030Z",
          "endsAt": "2026-07-19T01:09:55.030Z",
          "title": "Balayage",
          "clientName": "Email Only",
          "clientProfileId": null,
          "status": "WAITLIST",
          "locationType": null,
          "locationId": null,
          "durationMinutes": 0,
          "timeZone": "America/Los_Angeles",
          "timeZoneSource": "PROFESSIONAL",
          "localDateKey": "2026-07-18",
          "viewLocalDateKey": "2026-07-22",
          "preferenceLabel": "Any time",
          "offerHref": "/pro/bookings/new?clientId=cmrbry47n000bpo0dhw9pdc8b&offeringId=cmrbry49b0055po0dbbtbpp35",
          "waitlistEntryId": "cmrr3m7kl0003poai8vxy1mou",
          "serviceId": "cmrbry482000xpo0di0hbjtni",
          "offeringId": "cmrbry49b0055po0dbbtbpp35",
          "pendingOffer": null,
          "details": {
            "serviceName": "Balayage",
            "bufferMinutes": 0,
            "serviceItems": []
          }
        }
        """
    }

    @Test("a waitlist row decodes the ids the offer flow needs")
    func decodesOfferIdentifiers() throws {
        let event = try decode(offerableWaitlistRow)

        #expect(event.isWaitlist)
        #expect(event.waitlistEntryId == "cmrr3m7kl0003poai8vxy1mou")
        #expect(event.serviceId == "cmrbry482000xpo0di0hbjtni")
        #expect(event.offeringId == "cmrbry49b0055po0dbbtbpp35")
        #expect(event.pendingOffer == nil)
        // The row's own id stays namespaced; the offer route wants the bare one.
        #expect(event.id == "waitlist:cmrr3m7kl0003poai8vxy1mou")
        // Withheld by the chart-link gate, and not needed to make an offer.
        #expect(event.clientProfileId == nil)
        #expect(event.canOfferWaitlistTime)
    }

    @Test("an outstanding offer decodes so the row can show it instead")
    func decodesPendingOffer() throws {
        let json = offerableWaitlistRow.replacingOccurrences(
            of: "\"pendingOffer\": null",
            with: """
            "pendingOffer": {
                "id": "offer-1",
                "startsAt": "2026-07-24T17:00:00.000Z",
                "locationType": "SALON"
              }
            """
        )

        let event = try decode(json)
        #expect(event.pendingOffer?.id == "offer-1")
        #expect(event.pendingOffer?.startsAt == "2026-07-24T17:00:00.000Z")
        #expect(event.pendingOffer?.locationType == "SALON")
    }

    // The server nulls `offeringId` (and therefore `offerHref`) when the pro has
    // no active offering for the waited-on service. Neither platform shows an
    // offer action then — there is nothing bookable behind it.
    @Test("no active offering ⇒ nothing to offer")
    func noOfferingMeansNoAction() throws {
        let json = offerableWaitlistRow
            .replacingOccurrences(of: "\"offeringId\": \"cmrbry49b0055po0dbbtbpp35\"", with: "\"offeringId\": null")
            .replacingOccurrences(
                of: "\"offerHref\": \"/pro/bookings/new?clientId=cmrbry47n000bpo0dhw9pdc8b&offeringId=cmrbry49b0055po0dbbtbpp35\"",
                with: "\"offerHref\": null"
            )

        let event = try decode(json)
        #expect(event.offeringId == nil)
        #expect(event.offerHref == nil)
        #expect(!event.canOfferWaitlistTime)
    }

    // The deep-link fallback's only remaining reason to exist: a server that still
    // sends `offerHref` but not the ids the offer route needs (i.e. one older than
    // those fields). The row then falls through to "Book a time" rather than
    // showing nothing — the same order web's ManagementModal uses.
    @Test("an offerHref without the offer ids still leaves the deep-link")
    func fallsBackToTheDeepLink() throws {
        let json = offerableWaitlistRow
            .replacingOccurrences(
                of: "\"waitlistEntryId\": \"cmrr3m7kl0003poai8vxy1mou\"",
                with: "\"waitlistEntryId\": null"
            )
            .replacingOccurrences(
                of: "\"serviceId\": \"cmrbry482000xpo0di0hbjtni\"",
                with: "\"serviceId\": null"
            )

        let event = try decode(json)
        #expect(!event.canOfferWaitlistTime)
        #expect(event.offerHref != nil)
    }

    // ALLOW case: an ordinary booking event carries none of these keys, and must
    // still decode — the new fields are additive, not required.
    @Test("a plain booking row still decodes and is not offerable")
    func bookingRowUnaffected() throws {
        let event = try decode(
            """
            {
              "id": "booking-1",
              "kind": "BOOKING",
              "startsAt": "2026-07-22T17:00:00.000Z",
              "endsAt": "2026-07-22T18:00:00.000Z",
              "title": "Balayage",
              "clientName": "Dana Reed",
              "status": "ACCEPTED",
              "durationMinutes": 60,
              "timeZone": "America/Los_Angeles",
              "locationType": "SALON",
              "localDateKey": "2026-07-22"
            }
            """
        )

        #expect(!event.isWaitlist)
        #expect(event.waitlistEntryId == nil)
        #expect(event.pendingOffer == nil)
        #expect(!event.canOfferWaitlistTime)
    }
}
