import Foundation
import Testing
@testable import TovisKit

// Claiming a priority offer must land on the opening's OWN instant, never on a
// free-choice picker: `finalize` refuses any other minute with
// OPENING_NOT_AVAILABLE, and by the time a picker could appear the exclusive
// window has already been spent accepting. `claimableOpening` is the seam that
// resolves an accepted offer to the `ClientOpening` ClaimOpeningView takes.
//
// Both payloads below are VERBATIM captures against the local server
// (2026-07-19) — the priority offer from `GET /api/v1/client/priority-offer`
// while the row was PRIORITY_OFFERED, and the openings row from
// `GET /api/v1/client/openings` for the SAME row after accept flipped it to
// CLICKED. That ordering is the point: the openings feed excludes
// PRIORITY_OFFERED, so this resolution only works post-accept, and a hand-written
// fixture would hide that.
@Suite struct PriorityOfferClaimTargetTests {
    private let capturedOffers = """
    {
      "ok": true,
      "offers": [
        {
          "recipientId": "b2drive0recipient000000001",
          "status": "PRIORITY_OFFERED",
          "expiresAt": "2026-07-20T02:24:12.684Z",
          "expired": false,
          "proName": "TOVIS Test Pro",
          "proHref": "/professionals/cmrbry44b0003po0d5f1fcs2u",
          "professionalId": "cmrbry44b0003po0d5f1fcs2u",
          "avatarUrl": null,
          "serviceLabel": "Balayage",
          "serviceId": "cmrbry482000xpo0di0hbjtni",
          "offeringId": "cmrbry49b0055po0dbbtbpp35",
          "openingId": "b2drive0opening00000000001",
          "startAt": "2026-07-25T18:37:00.000Z",
          "endAt": "2026-07-25T21:37:00.000Z",
          "timeZone": "America/Los_Angeles",
          "locationType": "SALON",
          "note": "B2 drive fixture",
          "incentiveLabel": null,
          "claimHref": "/offerings/cmrbry49b0055po0dbbtbpp35?scheduledFor=2026-07-25T18%3A37%3A00.000Z&source=DISCOVERY&openingId=b2drive0opening00000000001&proTimeZone=America%2FLos_Angeles"
        }
      ]
    }
    """

    private let capturedOpenings = """
    {
      "ok": true,
      "notifications": [
        {
          "id": "b2drive0recipient000000001",
          "tier": "WAITLIST",
          "sentAt": "2026-07-19T20:24:12.684Z",
          "openedAt": null,
          "clickedAt": "2026-07-19T20:27:08.830Z",
          "bookedAt": null,
          "opening": {
            "id": "b2drive0opening00000000001",
            "professionalId": "cmrbry44b0003po0d5f1fcs2u",
            "startAt": "2026-07-25T18:37:00.000Z",
            "endAt": "2026-07-25T21:37:00.000Z",
            "note": "B2 drive fixture",
            "status": "ACTIVE",
            "visibilityMode": "PUBLIC_AT_DISCOVERY",
            "publicVisibleFrom": null,
            "publicVisibleUntil": null,
            "locationType": "SALON",
            "timeZone": "America/Los_Angeles",
            "professional": {
              "id": "cmrbry44b0003po0d5f1fcs2u",
              "businessName": "TOVIS Test Pro",
              "displayName": "TOVIS Test Pro",
              "handle": "tovis-test-pro",
              "avatarUrl": null,
              "professionType": "COSMETOLOGIST",
              "locationLabel": "Los Angeles, CA",
              "timeZone": "America/Los_Angeles"
            },
            "location": {
              "id": "cmrbry47t000fpo0dz0kdy80z",
              "type": "SALON",
              "timeZone": "America/Los_Angeles",
              "city": "Los Angeles",
              "state": "CA",
              "formattedAddress": "123 Test Salon Ave, Los Angeles, CA 90001",
              "lat": "34.052235",
              "lng": "-118.243683"
            },
            "services": [
              {
                "id": "b2drive0opensvc0000000001",
                "openingId": "b2drive0opening00000000001",
                "serviceId": "cmrbry482000xpo0di0hbjtni",
                "offeringId": "cmrbry49b0055po0dbbtbpp35",
                "sortOrder": 0,
                "service": {
                  "id": "cmrbry482000xpo0di0hbjtni",
                  "name": "Balayage",
                  "minPrice": "180",
                  "defaultDurationMinutes": 180
                },
                "offering": {
                  "id": "cmrbry49b0055po0dbbtbpp35",
                  "title": null,
                  "salonPriceStartingAt": "180",
                  "mobilePriceStartingAt": null,
                  "salonDurationMinutes": 180,
                  "mobileDurationMinutes": null,
                  "offersInSalon": true,
                  "offersMobile": false
                }
              }
            ],
            "publicIncentive": null
          }
        }
      ]
    }
    """

    private func decodedOffer() throws -> ClientPriorityOffer {
        let response = try JSONDecoder().decode(
            ClientPriorityOfferResponse.self,
            from: Data(capturedOffers.utf8)
        )
        return try #require(response.offers.first)
    }

    private func decodedOpenings() throws -> [ClientOpening] {
        try JSONDecoder().decode(
            ClientOpeningFeedResponse.self,
            from: Data(capturedOpenings.utf8)
        ).notifications
    }

    // MARK: - The resolution itself

    @Test("an accepted offer resolves to the opening carrying its own instant")
    func resolvesToMatchingOpening() throws {
        let offer = try decodedOffer()
        let resolved = try #require(offer.claimableOpening(in: try decodedOpenings()))

        #expect(resolved.opening.id == "b2drive0opening00000000001")
        // The whole point: the claim is pinned to the OFFERED minute, so finalize
        // cannot answer OPENING_NOT_AVAILABLE.
        #expect(resolved.startAt == offer.startAt)
        #expect(resolved.startAt == "2026-07-25T18:37:00.000Z")
    }

    @Test("the resolved opening carries everything the claim sheet renders")
    func resolvedOpeningIsFullyRenderable() throws {
        let offer = try decodedOffer()
        let resolved = try #require(offer.claimableOpening(in: try decodedOpenings()))

        // ClaimOpeningView renders from the feed row alone — no profile fetch and
        // no availability fetch — so these must be on the wire, not derived.
        #expect(resolved.offeringId == "cmrbry49b0055po0dbbtbpp35")
        #expect(resolved.serviceName == "Balayage")
        #expect(resolved.proName == "TOVIS Test Pro")
        #expect(resolved.claimLocationType == "SALON")
        #expect(resolved.claimLocationId == "cmrbry47t000fpo0dz0kdy80z")
        #expect(resolved.placeLine == "123 Test Salon Ave, Los Angeles, CA 90001")
        #expect(resolved.durationMinutes == 180)
        #expect(resolved.basePrice == Decimal(180))
        #expect(resolved.isMobile == false)
    }

    // MARK: - Every path that must NOT produce a claim target

    @Test("no openingId resolves to nil rather than to some other opening")
    func nilOpeningIdResolvesToNil() throws {
        let offers = try JSONDecoder().decode(
            ClientPriorityOfferResponse.self,
            from: Data(capturedOffers.replacingOccurrences(
                of: "\"openingId\": \"b2drive0opening00000000001\"",
                with: "\"openingId\": null"
            ).utf8)
        ).offers
        let offer = try #require(offers.first)

        #expect(offer.openingId == nil)
        #expect(offer.claimableOpening(in: try decodedOpenings()) == nil)
    }

    @Test("an offer whose opening is absent from the feed resolves to nil")
    func unmatchedOpeningResolvesToNil() throws {
        let offer = try decodedOffer()
        #expect(offer.claimableOpening(in: []) == nil)
    }

    @Test("a matched but non-bookable opening resolves to nil")
    func nonBookableOpeningResolvesToNil() throws {
        // An opening whose services carry no offering is not bookable; the openings
        // feed drops these and so must this, rather than handing the claim sheet a
        // row it cannot finalize.
        let openings = try JSONDecoder().decode(
            ClientOpeningFeedResponse.self,
            from: Data(capturedOpenings.replacingOccurrences(
                of: "\"offeringId\": \"cmrbry49b0055po0dbbtbpp35\"",
                with: "\"offeringId\": null"
            ).utf8)
        ).notifications

        let resolved = try #require(openings.first)
        #expect(resolved.isBookable == false)
        #expect(try decodedOffer().claimableOpening(in: openings) == nil)
    }

    @Test("resolution matches on openingId, not on position in the feed")
    func matchesByIdNotByOrder() throws {
        // A decoy row sits FIRST, so a `.first`-without-predicate implementation
        // would claim the wrong opening at the wrong time.
        let decoy = capturedOpenings
            .replacingOccurrences(of: "b2drive0opening00000000001", with: "decoy0opening000000000001")
            .replacingOccurrences(of: "2026-07-25T18:37:00.000Z", with: "2026-07-30T20:00:00.000Z")
        let decoyRows = try JSONDecoder().decode(
            ClientOpeningFeedResponse.self, from: Data(decoy.utf8)
        ).notifications

        let feed = decoyRows + (try decodedOpenings())
        let resolved = try #require(try decodedOffer().claimableOpening(in: feed))

        #expect(resolved.opening.id == "b2drive0opening00000000001")
        #expect(resolved.startAt == "2026-07-25T18:37:00.000Z")
    }
}
