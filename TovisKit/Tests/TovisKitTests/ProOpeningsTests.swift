import Foundation
import Testing
@testable import TovisKit

// Proves the pro "Last Minute" OPENINGS methods hit the right routes with the
// right verbs, query, and bodies (all existing web routes — an iOS-only port):
//   • listOpenings   → GET    /pro/openings?hours=&take=   → decodes openings
//   • createOpening  → POST   /pro/openings                {slot + tier plans}
//   • cancelOpening  → DELETE /pro/openings?id=
// Tier-plan requests are a discriminated union: only the field relevant to the
// offer type is emitted (nil fields drop out of the JSON).

/// Records the outgoing request and serves a canned envelope.
final class ProOpeningsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedQuery: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedQuery = request.url?.query
        Self.capturedMethod = request.httpMethod
        Self.capturedBody = request.httpBody ?? request.openingsBodyStreamData()

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

private extension URLRequest {
    func openingsBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

@Suite(.serialized) struct ProOpeningsTests {
    /// A fully-populated opening the DTO can decode (services + a tier plan).
    private static let openingJSON = """
    {
      "id":"op_1","status":"ACTIVE","visibilityMode":"PUBLIC_AT_DISCOVERY",
      "startAt":"2026-07-11T18:00:00Z","endAt":"2026-07-11T20:00:00Z","note":"Fresh cut",
      "locationType":"SALON","timeZone":"America/New_York","recipientCount":3,
      "location":{"name":"Downtown","formattedAddress":"1 Main St"},
      "services":[{"id":"os_1","serviceId":"svc_1","service":{"name":"Cut","minPrice":"80"}}],
      "tierPlans":[{"id":"tp_1","tier":"WAITLIST","scheduledFor":"2026-07-10T18:00:00Z","offerType":"PERCENT_OFF","percentOff":10}]
    }
    """

    private func makeService() async -> ProScheduleService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProOpeningsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.openings.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProScheduleService(api: api)
    }

    private func reset(response: String) {
        ProOpeningsURLProtocol.capturedPath = nil
        ProOpeningsURLProtocol.capturedQuery = nil
        ProOpeningsURLProtocol.capturedMethod = nil
        ProOpeningsURLProtocol.capturedBody = nil
        ProOpeningsURLProtocol.status = 200
        ProOpeningsURLProtocol.responseBody = Data(response.utf8)
    }

    private func bodyJSON() throws -> [String: Any] {
        let body = try #require(ProOpeningsURLProtocol.capturedBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func listOpeningsGetsWithWindowQueryAndDecodes() async throws {
        reset(response: "{\"ok\":true,\"openings\":[\(Self.openingJSON)]}")

        let openings = try await makeService().listOpenings()

        #expect(ProOpeningsURLProtocol.capturedPath == "/api/v1/pro/openings")
        #expect(ProOpeningsURLProtocol.capturedMethod == "GET")
        let query = try #require(ProOpeningsURLProtocol.capturedQuery)
        #expect(query.contains("hours=48"))
        #expect(query.contains("take=100"))

        #expect(openings.count == 1)
        let opening = try #require(openings.first)
        #expect(opening.id == "op_1")
        #expect(opening.recipientCount == 3)
        #expect(opening.services.first?.service.name == "Cut")
        #expect(opening.tierPlans.first?.percentOff == 10)
        #expect(opening.location?.name == "Downtown")
    }

    @Test func listOpeningsPassesCustomWindow() async throws {
        reset(response: "{\"ok\":true,\"openings\":[]}")
        _ = try await makeService().listOpenings(hours: 24, take: 10)
        let query = try #require(ProOpeningsURLProtocol.capturedQuery)
        #expect(query.contains("hours=24"))
        #expect(query.contains("take=10"))
    }

    @Test func createOpeningPostsSlotAndTierPlans() async throws {
        reset(response: "{\"ok\":true,\"opening\":\(Self.openingJSON)}")

        let request = ProOpeningCreateRequest(
            offeringIds: ["off_1", "off_2"],
            startAt: "2026-07-11T18:00:00Z",
            endAt: "2026-07-11T20:00:00Z",
            locationType: "SALON",
            visibilityMode: "PUBLIC_IMMEDIATE",
            note: "Fresh cut",
            tierPlans: [
                ProOpeningTierPlanRequest(tier: "WAITLIST", offerType: "NONE"),
                ProOpeningTierPlanRequest(tier: "REACTIVATION", offerType: "PERCENT_OFF", percentOff: 15),
                ProOpeningTierPlanRequest(tier: "DISCOVERY", offerType: "AMOUNT_OFF", amountOff: "20"),
            ]
        )
        let created = try await makeService().createOpening(request)

        #expect(ProOpeningsURLProtocol.capturedPath == "/api/v1/pro/openings")
        #expect(ProOpeningsURLProtocol.capturedMethod == "POST")
        #expect(created.id == "op_1")

        let json = try bodyJSON()
        #expect((json["offeringIds"] as? [String])?.count == 2)
        #expect(json["startAt"] as? String == "2026-07-11T18:00:00Z")
        #expect(json["endAt"] as? String == "2026-07-11T20:00:00Z")
        #expect(json["locationType"] as? String == "SALON")
        #expect(json["visibilityMode"] as? String == "PUBLIC_IMMEDIATE")
        #expect(json["note"] as? String == "Fresh cut")

        let plans = try #require(json["tierPlans"] as? [[String: Any]])
        #expect(plans.count == 3)

        let waitlist = try #require(plans.first { $0["tier"] as? String == "WAITLIST" })
        #expect(waitlist["offerType"] as? String == "NONE")
        // A NONE plan carries no incentive fields (nil dropped from the JSON).
        #expect(waitlist["percentOff"] == nil)
        #expect(waitlist["amountOff"] == nil)
        #expect(waitlist["freeAddOnServiceId"] == nil)

        let reactivation = try #require(plans.first { $0["tier"] as? String == "REACTIVATION" })
        #expect(reactivation["percentOff"] as? Int == 15)
        #expect(reactivation["amountOff"] == nil)

        let discovery = try #require(plans.first { $0["tier"] as? String == "DISCOVERY" })
        #expect(discovery["amountOff"] as? String == "20")
        #expect(discovery["percentOff"] == nil)
    }

    @Test func createOpeningOmitsNilEndAtAndNote() async throws {
        reset(response: "{\"ok\":true,\"opening\":\(Self.openingJSON)}")

        let request = ProOpeningCreateRequest(
            offeringIds: ["off_1"],
            startAt: "2026-07-11T18:00:00Z",
            endAt: nil,
            locationType: "MOBILE",
            visibilityMode: "TARGETED_ONLY",
            note: nil,
            tierPlans: [ProOpeningTierPlanRequest(tier: "WAITLIST", offerType: "FREE_SERVICE")]
        )
        _ = try await makeService().createOpening(request)

        let json = try bodyJSON()
        #expect(json["endAt"] == nil)
        #expect(json["note"] == nil)
        #expect(json["locationType"] as? String == "MOBILE")
    }

    // MARK: - Client visibility (tovis-app F16)

    /// The same opening, plus the server's verdict on whether clients can still
    /// see its time.
    private static func openingJSON(visibility: String) -> String {
        """
        {
          "id":"op_1","status":"ACTIVE","visibilityMode":"PUBLIC_AT_DISCOVERY",
          "startAt":"2026-07-11T18:00:00Z","endAt":null,"note":null,
          "locationType":"SALON","timeZone":"America/New_York","recipientCount":3,
          "clientVisibility":"\(visibility)",
          "location":null,"services":[],"tierPlans":[]
        }
        """
    }

    private func firstOpening(visibility: String) async throws -> ProOpeningDto {
        reset(response: "{\"ok\":true,\"openings\":[\(Self.openingJSON(visibility: visibility))]}")
        return try #require(try await makeService().listOpenings().first)
    }

    @Test func decodesTheVisibilityVerdictAndItsCopy() async throws {
        let opening = try await firstOpening(visibility: "TIME_BOOKED")

        #expect(opening.visibility == .timeBooked)
        #expect(opening.visibility.isFault)
        #expect(opening.visibility.noticeText
            == "Not visible to clients — that time is already booked.")
    }

    /// A hold on the slot is usually a client mid-claim on THIS opening — the
    /// feature working. It gets copy, but must not be dressed up as a fault.
    @Test func aClaimInFlightIsSaidWithoutBeingCalledAFault() async throws {
        let opening = try await firstOpening(visibility: "BEING_CLAIMED")

        #expect(opening.visibility == .beingClaimed)
        #expect(opening.visibility.isFault == false)
        #expect(opening.visibility.noticeText
            == "On hold — a booking for this time is in progress.")
    }

    // ALLOW CASE ×3. A card that badges everything would satisfy every
    // assertion above; these are what pin it to silence when there is nothing
    // to say — including against a server older or newer than this build.
    @Test func saysNothingWhenThereIsNothingToSay() async throws {
        let live = try await firstOpening(visibility: "VISIBLE")
        #expect(live.visibility == .visible)
        #expect(live.visibility.noticeText == nil)
        #expect(live.visibility.isFault == false)

        // A server that grew a state this build has never heard of.
        let unknown = try await firstOpening(visibility: "SOMETHING_NEW")
        #expect(unknown.visibility == .notChecked)
        #expect(unknown.visibility.noticeText == nil)

        // An older server, which sends no such key at all — the original
        // fixture, decoded by the same path.
        reset(response: "{\"ok\":true,\"openings\":[\(Self.openingJSON)]}")
        let legacy = try #require(try await makeService().listOpenings().first)
        #expect(legacy.clientVisibility == nil)
        #expect(legacy.visibility == .notChecked)
        #expect(legacy.visibility.noticeText == nil)
    }

    /// Exactly the two silent states are silent, and every other state both
    /// says something and is a fault. Pins the table against a case added later
    /// with a nil `noticeText` — which would render as no badge at all.
    @Test func everyStateIsEitherSilentOrExplained() {
        for state in ProOpeningClientVisibility.allCases {
            switch state {
            case .visible, .notChecked:
                #expect(state.noticeText == nil)
                #expect(state.isFault == false)
            case .beingClaimed:
                #expect(state.noticeText != nil)
                #expect(state.isFault == false)
            default:
                #expect(state.noticeText != nil, "\(state.rawValue) says nothing")
                #expect(state.isFault, "\(state.rawValue) is not flagged")
            }
        }
    }

    @Test func cancelOpeningSendsIdQuery() async throws {
        reset(response: "{\"ok\":true,\"id\":\"op_1\",\"alreadyCancelled\":false}")

        try await makeService().cancelOpening(id: "op_1")

        #expect(ProOpeningsURLProtocol.capturedPath == "/api/v1/pro/openings")
        #expect(ProOpeningsURLProtocol.capturedMethod == "DELETE")
        #expect(ProOpeningsURLProtocol.capturedQuery == "id=op_1")
    }
}
