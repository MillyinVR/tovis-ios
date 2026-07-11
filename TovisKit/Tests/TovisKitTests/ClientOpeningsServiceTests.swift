import Foundation
import Testing
@testable import TovisKit

// Proves the client openings feed on HomeService:
//   • openings() → GET /client/openings → { ok, notifications }  (envelope unwrapped)
//   • optional serviceId / professionalId / locationType filters ride the query
//   • ClientOpening card derivation mirrors the web parseCard: primary service →
//     offering, pro/service-name fallbacks, meta line, matched-waitlist badge, and
//     the discounted-price math (PERCENT_OFF / AMOUNT_OFF, base salon-vs-mobile).

/// Records the outgoing request and serves a canned envelope.
final class OpeningsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedQuery: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedQuery = request.url?.query
        Self.capturedMethod = request.httpMethod

        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct ClientOpeningsServiceTests {
    private func makeService() async -> HomeService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpeningsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.openings.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return HomeService(api: api)
    }

    private func reset(_ body: Data = Data("{\"ok\":true}".utf8)) {
        OpeningsURLProtocol.capturedPath = nil
        OpeningsURLProtocol.capturedQuery = nil
        OpeningsURLProtocol.capturedMethod = nil
        OpeningsURLProtocol.status = 200
        OpeningsURLProtocol.responseBody = body
    }

    // Three rows: a percent-off matched-waitlist salon opening, an amount-off mobile
    // opening with pro/title fallbacks, and a bare no-services (non-bookable) opening.
    private let feedJSON = """
    {
      "ok": true,
      "notifications": [
        {
          "id": "rcp_1",
          "tier": "WAITLIST",
          "sentAt": "2026-07-10T12:00:00.000Z",
          "opening": {
            "id": "opn_1",
            "professionalId": "pro_1",
            "startAt": "2026-07-11T18:00:00.000Z",
            "endAt": "2026-07-11T19:00:00.000Z",
            "note": null,
            "status": "ACTIVE",
            "locationType": "SALON",
            "timeZone": "America/New_York",
            "professional": {
              "id": "pro_1",
              "businessName": "Glow Studio",
              "displayName": "Glow Studio",
              "handle": "glow",
              "avatarUrl": "https://cdn/a.jpg",
              "professionType": "HAIR_STYLIST",
              "locationLabel": "Brooklyn, NY",
              "timeZone": "America/New_York"
            },
            "location": null,
            "services": [
              {
                "id": "os_1",
                "openingId": "opn_1",
                "serviceId": "svc_1",
                "offeringId": "off_1",
                "sortOrder": 0,
                "service": { "id": "svc_1", "name": "Balayage", "minPrice": "150.00", "defaultDurationMinutes": 120 },
                "offering": {
                  "id": "off_1", "title": "Signature Balayage",
                  "salonPriceStartingAt": "120.00", "mobilePriceStartingAt": null,
                  "salonDurationMinutes": 120, "mobileDurationMinutes": null,
                  "offersInSalon": true, "offersMobile": false
                }
              }
            ],
            "publicIncentive": {
              "tier": "WAITLIST", "offerType": "PERCENT_OFF", "label": "20% off",
              "percentOff": 20, "amountOff": null, "freeAddOnService": null
            }
          }
        },
        {
          "id": "rcp_2",
          "tier": "TIER_2",
          "sentAt": "2026-07-10T11:00:00.000Z",
          "opening": {
            "id": "opn_2",
            "professionalId": "pro_2",
            "startAt": "2026-07-12T15:30:00.000Z",
            "endAt": null,
            "status": "ACTIVE",
            "locationType": "MOBILE",
            "timeZone": "America/Los_Angeles",
            "professional": {
              "id": "pro_2",
              "businessName": null,
              "displayName": null,
              "handle": "kai",
              "avatarUrl": null,
              "locationLabel": null,
              "timeZone": "America/Los_Angeles"
            },
            "services": [
              {
                "id": "os_2",
                "openingId": "opn_2",
                "serviceId": "svc_2",
                "offeringId": "off_2",
                "sortOrder": 0,
                "service": { "id": "svc_2", "name": "Men’s Cut", "minPrice": "70.00", "defaultDurationMinutes": 45 },
                "offering": {
                  "id": "off_2", "title": null,
                  "salonPriceStartingAt": null, "mobilePriceStartingAt": "80.00",
                  "offersInSalon": false, "offersMobile": true
                }
              }
            ],
            "publicIncentive": {
              "tier": "TIER_2", "offerType": "AMOUNT_OFF", "label": "$15 off",
              "percentOff": null, "amountOff": "15.00", "freeAddOnService": null
            }
          }
        },
        {
          "id": "rcp_3",
          "tier": null,
          "sentAt": "2026-07-10T10:00:00.000Z",
          "opening": {
            "id": "opn_3",
            "professionalId": "pro_3",
            "startAt": "2026-07-13T13:00:00.000Z",
            "status": "ACTIVE",
            "locationType": "SALON",
            "timeZone": "UTC",
            "professional": { "id": "pro_3" },
            "services": []
          }
        }
      ]
    }
    """

    // MARK: - openings() route + envelope

    @Test func openingsHitsRouteAndUnwrapsEnvelope() async throws {
        reset(Data(feedJSON.utf8))
        let service = await makeService()

        let rows = try await service.openings()

        #expect(OpeningsURLProtocol.capturedPath == "/api/v1/client/openings")
        #expect(OpeningsURLProtocol.capturedMethod == "GET")
        // No filters → no query string.
        #expect(OpeningsURLProtocol.capturedQuery == nil)
        #expect(rows.count == 3)
    }

    @Test func openingsPassesFiltersAsQuery() async throws {
        reset(Data("{\"ok\":true,\"notifications\":[]}".utf8))
        let service = await makeService()

        _ = try await service.openings(serviceId: "svc_1", professionalId: "pro_1", locationType: "SALON")

        let query = try #require(OpeningsURLProtocol.capturedQuery)
        #expect(query.contains("serviceId=svc_1"))
        #expect(query.contains("professionalId=pro_1"))
        #expect(query.contains("locationType=SALON"))
    }

    // MARK: - card derivation (percent-off, matched-waitlist, salon)

    @Test func percentOffSalonRowDerivesCard() async throws {
        reset(Data(feedJSON.utf8))
        let service = await makeService()

        let first = try #require(try await service.openings().first)
        #expect(first.id == "rcp_1")
        #expect(first.isBookable)
        #expect(first.offeringId == "off_1")
        #expect(first.serviceId == "svc_1")
        #expect(first.serviceName == "Signature Balayage")   // offering.title wins
        #expect(first.proName == "Glow Studio")
        #expect(first.meta == "Glow Studio · Brooklyn, NY")
        #expect(first.matchedWaitlist)
        #expect(first.incentiveLabel == "20% off")
        // Salon base 120, 20% off → 96, discount shown.
        #expect(first.basePrice == Decimal(120))
        #expect(first.finalPrice == Decimal(96))
        #expect(first.hasDiscount)
    }

    // MARK: - card derivation (amount-off, mobile, fallbacks)

    @Test func amountOffMobileRowDerivesCardWithFallbacks() async throws {
        reset(Data(feedJSON.utf8))
        let service = await makeService()

        let rows = try await service.openings()
        let second = try #require(rows.dropFirst().first)
        #expect(second.id == "rcp_2")
        #expect(second.isBookable)
        #expect(second.offeringId == "off_2")
        #expect(second.serviceName == "Men’s Cut")          // offering.title null → service.name
        #expect(second.proName == "Your pro")               // no display/business name (no handle fallback)
        #expect(second.meta == "Your pro")                  // no location label
        #expect(!second.matchedWaitlist)
        // Mobile base 80, $15 off → 65, discount shown.
        #expect(second.basePrice == Decimal(80))
        #expect(second.finalPrice == Decimal(65))
        #expect(second.hasDiscount)
    }

    // MARK: - non-bookable row (no services)

    @Test func bareRowIsNotBookable() async throws {
        reset(Data(feedJSON.utf8))
        let service = await makeService()

        let third = try #require(try await service.openings().last)
        #expect(third.id == "rcp_3")
        #expect(!third.isBookable)
        #expect(third.offeringId == nil)
        #expect(third.serviceName == "Last-minute opening")
        #expect(third.proName == "Your pro")
        #expect(third.basePrice == nil)
        #expect(third.finalPrice == nil)
        #expect(!third.hasDiscount)
        #expect(!third.matchedWaitlist)
    }

    // MARK: - discount edge (amount off ≥ base does not apply)

    @Test func amountOffNotBelowBaseIsIgnored() throws {
        // An AMOUNT_OFF that isn't strictly less than the base leaves the price at base
        // (mirrors parseCard's `amt < baseNum` guard) — no struck-through "was".
        let json = """
        {
          "ok": true,
          "notifications": [{
            "id": "rcp_x", "tier": null, "sentAt": "2026-07-10T10:00:00.000Z",
            "opening": {
              "id": "opn_x", "professionalId": "pro_x", "startAt": "2026-07-13T13:00:00.000Z",
              "status": "ACTIVE", "locationType": "SALON", "timeZone": "UTC",
              "professional": { "id": "pro_x", "displayName": "Studio X" },
              "services": [{
                "id": "os_x", "openingId": "opn_x", "serviceId": "svc_x", "offeringId": "off_x", "sortOrder": 0,
                "service": { "id": "svc_x", "name": "Trim", "minPrice": "40.00", "defaultDurationMinutes": 30 },
                "offering": { "id": "off_x", "title": "Trim", "salonPriceStartingAt": "40.00",
                              "mobilePriceStartingAt": null, "offersInSalon": true, "offersMobile": false }
              }],
              "publicIncentive": { "tier": "TIER_1", "offerType": "AMOUNT_OFF", "label": "$50 off",
                                   "percentOff": null, "amountOff": "50.00", "freeAddOnService": null }
            }
          }]
        }
        """
        let feed = try JSONDecoder().decode(ClientOpeningFeedResponse.self, from: Data(json.utf8))
        let row = try #require(feed.notifications.first)
        #expect(row.basePrice == Decimal(40))
        #expect(row.finalPrice == Decimal(40))   // $50 off > $40 base → no-op
        #expect(!row.hasDiscount)
    }
}
