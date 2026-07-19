import Foundation
import Testing
@testable import TovisKit

// The claim sheet renders and claims from the feed row ALONE — no profile fetch,
// no availability fetch. That only works if every field it needs is genuinely on
// the wire, so the payload below is a VERBATIM capture from
// `GET /api/v1/client/openings` (local server, 2026-07-19), not a hand-written
// shape that agrees with what the reader expects. The `location` block in
// particular was on the wire all along and simply wasn't decoded.
@Suite struct ClientOpeningClaimFieldsTests {
    private let capturedFeed = """
    {
      "ok": true,
      "notifications": [
        {
          "id": "cmrr3m7kh0001poaiy4eesgef",
          "tier": "WAITLIST",
          "sentAt": "2026-07-19T01:09:55.025Z",
          "openedAt": null,
          "clickedAt": null,
          "bookedAt": null,
          "opening": {
            "id": "cmrr5a7u7000kpo3ns5irr4i7",
            "professionalId": "cmrbry44b0003po0d5f1fcs2u",
            "startAt": "2026-07-20T17:00:00.000Z",
            "endAt": "2026-07-20T20:00:00.000Z",
            "note": "Cancellation — grab it",
            "status": "ACTIVE",
            "visibilityMode": "PUBLIC_AT_DISCOVERY",
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
                "id": "cmrr5a7u7000mpo3nlcgsxbf1",
                "openingId": "cmrr5a7u7000kpo3ns5irr4i7",
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
                  "title": "Balayage",
                  "salonPriceStartingAt": "180",
                  "mobilePriceStartingAt": null,
                  "salonDurationMinutes": 180,
                  "mobileDurationMinutes": null,
                  "offersInSalon": true,
                  "offersMobile": false
                }
              }
            ],
            "publicIncentive": {
              "tier": "WAITLIST",
              "offerType": "PERCENT_OFF",
              "label": "20% off",
              "percentOff": 20,
              "amountOff": null,
              "freeAddOnService": null
            }
          }
        }
      ]
    }
    """

    private func decodeFirst() throws -> ClientOpening {
        let response = try JSONDecoder().decode(
            ClientOpeningFeedResponse.self,
            from: Data(capturedFeed.utf8)
        )
        return try #require(response.notifications.first)
    }

    @Test func carriesEverythingTheClaimNeeds() throws {
        let opening = try decodeFirst()

        // Exactly the arguments hold + finalize are called with.
        #expect(opening.offeringId == "cmrbry49b0055po0dbbtbpp35")
        #expect(opening.opening.id == "cmrr5a7u7000kpo3ns5irr4i7")
        #expect(opening.startAt == "2026-07-20T17:00:00.000Z")
        #expect(opening.claimLocationType == "SALON")
        #expect(opening.claimLocationId == "cmrbry47t000fpo0dz0kdy80z")
        #expect(opening.isMobile == false)
        #expect(opening.isBookable)
    }

    @Test func rendersTheWebClaimPageFacts() throws {
        let opening = try decodeFirst()

        #expect(opening.serviceName == "Balayage")
        #expect(opening.proName == "TOVIS Test Pro")
        #expect(opening.professionLabel == "Cosmetologist")
        #expect(opening.placeLine == "123 Test Salon Ave, Los Angeles, CA 90001")
        #expect(opening.durationMinutes == 180)
        #expect(opening.incentiveLabel == "20% off")
        #expect(opening.basePrice == Decimal(180))
        #expect(opening.finalPrice == Decimal(144)) // 20% off 180
        #expect(opening.hasDiscount)
    }

    // The incentive is the headline on both the feed card and the claim sheet, so
    // every offer type a pro can pick has to produce something sayable. The label
    // itself comes from the server (`incentiveLabel` in openingDto.ts) — these pin
    // the framing the client puts around it.
    @Test func everyOfferTypeGetsAHeadlineAndContext() throws {
        let cases: [(String, String, String, String)] = [
            ("PERCENT_OFF", "20% off", "20% OFF", "Off this last-minute opening"),
            ("AMOUNT_OFF", "$15 off", "$15 OFF", "Off this last-minute opening"),
            ("FREE_SERVICE", "Free service", "FREE SERVICE", "This last-minute opening is on your pro"),
            ("FREE_ADD_ON", "Deep conditioning", "DEEP CONDITIONING", "Free add-on with this last-minute opening"),
        ]

        for (offerType, label, headline, subline) in cases {
            let json = """
            {"ok":true,"notifications":[{"id":"r","tier":null,"opening":{
              "id":"o","professionalId":"p","startAt":"2026-07-20T17:00:00.000Z",
              "professional":{"id":"p"},
              "publicIncentive":{"offerType":"\(offerType)","label":"\(label)"}
            }}]}
            """
            let response = try JSONDecoder().decode(
                ClientOpeningFeedResponse.self, from: Data(json.utf8)
            )
            let opening = try #require(response.notifications.first)
            #expect(opening.incentiveHeadline == headline, "\(offerType) headline")
            #expect(opening.incentiveSubline == subline, "\(offerType) subline")
        }
    }

    // No incentive → no banner. The screen must not reserve space for a deal that
    // isn't there, and must not render an empty accent block.
    @Test func noIncentiveMeansNoHeadline() throws {
        let opening = try decodeFirstWithoutIncentive()
        #expect(opening.incentiveLabel == nil)
        #expect(opening.incentiveHeadline == nil)
        #expect(opening.incentiveSubline == nil)
        #expect(opening.hasDiscount == false)
    }

    private func decodeFirstWithoutIncentive() throws -> ClientOpening {
        let json = """
        {"ok":true,"notifications":[{"id":"r","tier":null,"opening":{
          "id":"o","professionalId":"p","startAt":"2026-07-20T17:00:00.000Z",
          "professional":{"id":"p"},"publicIncentive":null,
          "services":[{"id":"os","serviceId":"s","offeringId":"off",
            "service":{"id":"s","name":"Cut","minPrice":"70"},
            "offering":{"id":"off","salonPriceStartingAt":"70","offersInSalon":true}}]
        }}]}
        """
        let response = try JSONDecoder().decode(
            ClientOpeningFeedResponse.self, from: Data(json.utf8)
        )
        return try #require(response.notifications.first)
    }

    // A MOBILE opening has no salon row, so `location` is null. The claim must
    // still work: `locationId` is a hint the hold route falls back from.
    @Test func mobileOpeningWithNoLocationStillClaims() throws {
        // The recipient feed sends `"location": null` for a MOBILE opening — see
        // the DTO's own note that it "makes location nullable".
        let json = """
        {"ok":true,"notifications":[{"id":"r2","tier":"TIER_2","opening":{
          "id":"o2","professionalId":"p2","startAt":"2026-07-21T17:00:00.000Z",
          "locationType":"MOBILE","timeZone":"America/Los_Angeles","location":null,
          "professional":{"id":"p2","displayName":"Kai"},
          "services":[{"id":"os2","serviceId":"svc2","offeringId":"off2",
            "service":{"id":"svc2","name":"Men’s Cut","minPrice":"70","defaultDurationMinutes":45},
            "offering":{"id":"off2","mobilePriceStartingAt":"80","mobileDurationMinutes":60,
              "offersInSalon":false,"offersMobile":true}}]
        }}]}
        """
        let response = try JSONDecoder().decode(
            ClientOpeningFeedResponse.self, from: Data(json.utf8)
        )
        let opening = try #require(response.notifications.first)

        #expect(opening.claimLocationType == "MOBILE")
        #expect(opening.isMobile)
        #expect(opening.claimLocationId == nil)
        // Still bookable — the offering id is what makes a claim possible.
        #expect(opening.isBookable)
        // Mobile pricing + duration, not the salon columns.
        #expect(opening.basePrice == Decimal(80))
        #expect(opening.durationMinutes == 60)
        #expect(opening.placeLine == nil)
    }

    // Nothing about the claim path may THROW on a sparse payload: the whole feed
    // would fail to decode and the screen would show an error instead of openings.
    @Test func decodesWithNoLocationBlockAtAll() throws {
        let json = """
        {"ok":true,"notifications":[{"id":"r1","tier":null,"opening":{
          "id":"o1","professionalId":"p1","startAt":"2026-07-20T17:00:00.000Z",
          "professional":{"id":"p1"}
        }}]}
        """
        let response = try JSONDecoder().decode(
            ClientOpeningFeedResponse.self, from: Data(json.utf8)
        )
        let opening = try #require(response.notifications.first)

        #expect(opening.claimLocationId == nil)
        #expect(opening.claimLocationType == "SALON") // the endpoints' own default
        #expect(opening.placeLine == nil)
        #expect(opening.durationMinutes == nil)
        #expect(opening.isBookable == false) // no offering → not claimable
    }
}

// The home card's incentive badge is fed by a field added in a paired web change,
// so it MUST be optional: a non-optional one would throw and take the whole home
// tab down against current production, where the key is absent.
@Suite struct HomeInviteIncentiveTests {
    private func decodeOpening(_ json: String) throws -> HomeOpening {
        try JSONDecoder().decode(HomeOpening.self, from: Data(json.utf8))
    }

    @Test func headlineComesFromTheServerLabel() throws {
        let opening = try decodeOpening("""
        {"id":"o","startAt":"2026-07-22T18:00:00.000Z",
         "professional":{"id":"p","displayName":"Kai"},
         "publicIncentive":{"offerType":"AMOUNT_OFF","label":"$40 off"}}
        """)
        #expect(opening.incentiveHeadline == "$40 OFF")
    }

    @Test func absentIncentiveDecodesAndShowsNoBadge() throws {
        // Exactly the payload today's production sends — no `publicIncentive` key.
        let opening = try decodeOpening("""
        {"id":"o","startAt":"2026-07-22T18:00:00.000Z",
         "professional":{"id":"p","displayName":"Kai"}}
        """)
        #expect(opening.publicIncentive == nil)
        #expect(opening.incentiveHeadline == nil)
    }

    @Test func explicitNullIncentiveShowsNoBadge() throws {
        let opening = try decodeOpening("""
        {"id":"o","startAt":"2026-07-22T18:00:00.000Z",
         "professional":{"id":"p","displayName":"Kai"},"publicIncentive":null}
        """)
        #expect(opening.incentiveHeadline == nil)
    }

    @Test func blankLabelIsNotABadge() throws {
        let opening = try decodeOpening("""
        {"id":"o","startAt":"2026-07-22T18:00:00.000Z",
         "professional":{"id":"p","displayName":"Kai"},
         "publicIncentive":{"offerType":"PERCENT_OFF","label":"   "}}
        """)
        #expect(opening.incentiveHeadline == nil)
    }
}
