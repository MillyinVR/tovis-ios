import Foundation
import Testing
@testable import TovisKit

// Book the Look, slice B8 — pins what the CONSULT path actually puts on the
// wire. Every one of these was a silent-failure risk rather than a crash: a
// dropped `consultId` does not throw, it books the FLOOR offering's width at
// the FLOOR offering's price, and nobody finds out until the pro's day breaks.
//
// The absence cases matter just as much: an ordinary booking must send NONE of
// these fields, so its body — and the idempotency key derived from it — is
// byte-identical to what shipped builds send.

/// Records the outgoing request (body, URL, method) and serves a canned reply.
final class ConsultWireURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedURL: URL?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var responseBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedURL = request.url
        Self.capturedBody = request.httpBody ?? request.consultWireBodyStreamData()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func consultWireBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ConsultBookingWireTests {
    private func api() async -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsultWireURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.consultwire.tests")
        await tokenStore.save("session.token.value")
        return APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
    }

    private func reset(_ response: String) {
        ConsultWireURLProtocol.capturedURL = nil
        ConsultWireURLProtocol.capturedBody = nil
        ConsultWireURLProtocol.responseBody = Data(response.utf8)
    }

    private func bodyJSON() throws -> [String: Any] {
        let body = try #require(ConsultWireURLProtocol.capturedBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func queryItems() throws -> [String: String] {
        let url = try #require(ConsultWireURLProtocol.capturedURL)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private static let holdResponse = """
    {"ok":true,"hold":{"id":"hold_1","expiresAt":"2026-07-10T17:05:00.000Z",
     "scheduledFor":"2026-07-10T17:00:00.000Z","locationType":"SALON",
     "locationId":"loc_1","durationMinutes":270}}
    """

    private static let finalizeResponse = """
    {"ok":true,"booking":{"id":"bk_1","status":"PENDING",
     "scheduledFor":"2026-07-10T17:00:00.000Z","professionalId":"pro_1"}}
    """

    private static let proposalResponse = """
    {"ok":true,"proposal":{"available":false,"reason":"MODE_NOT_OFFERED",
     "proposal":null,"professionalId":"pro_1"}}
    """

    // MARK: - The hold

    /// 🔴 Without `consultId` the reservation is sized by the FLOOR offering's
    /// base, and the appointment the client is committing to is wider than the
    /// slot that was held — decision 11's duration miss, which breaks the pro's
    /// day rather than being corrected in the chair.
    @Test func aConsultHoldNamesTheConsult() async throws {
        reset(Self.holdResponse)
        _ = try await BookingService(api: await api()).createHold(
            offeringId: "off_1", locationId: "loc_1",
            scheduledFor: "2026-07-10T17:00:00.000Z",
            consultId: "consult_1")

        let json = try bodyJSON()
        #expect(json["consultId"] as? String == "consult_1")
        // 🔴 NEVER together: an `OfferingAddOn` on top of a consult proposal is
        // refused by the route AND the write boundary.
        #expect((json["addOnIds"] as? [String])?.isEmpty == true)
    }

    @Test func anOrdinaryHoldSendsNoConsultIdAtAll() async throws {
        reset(Self.holdResponse)
        _ = try await BookingService(api: await api()).createHold(
            offeringId: "off_1", locationId: "loc_1",
            scheduledFor: "2026-07-10T17:00:00.000Z")

        #expect(try bodyJSON()["consultId"] == nil)
    }

    // MARK: - The finalize

    @Test func aConsultFinalizeCarriesTheStampTheLookAndTheTickedIds() async throws {
        reset(Self.finalizeResponse)
        _ = try await BookingService(api: await api()).finalize(
            holdId: "hold_1", offeringId: "off_1", locationType: "SALON",
            addOnIds: [], source: "DISCOVERY",
            lookPostId: "look_1", consultId: "consult_1",
            consultEnhancementLineIds: ["line_a", "line_b"])

        let json = try bodyJSON()
        #expect(json["consultId"] as? String == "consult_1")
        #expect(json["lookPostId"] as? String == "look_1")
        #expect(json["consultEnhancementLineIds"] as? [String] == ["line_a", "line_b"])
        #expect(json["source"] as? String == "DISCOVERY")
    }

    /// The floor alone. An EMPTY list is a real answer — "she chose nothing" —
    /// and is what the server reads as the floor, so it must survive the encode
    /// rather than being dropped as if it were absent.
    @Test func aConsultFinalizeWithNothingTickedStillSendsAnEmptyList() async throws {
        reset(Self.finalizeResponse)
        _ = try await BookingService(api: await api()).finalize(
            holdId: "hold_1", offeringId: "off_1",
            lookPostId: "look_1", consultId: "consult_1",
            consultEnhancementLineIds: [])

        let json = try bodyJSON()
        #expect(json["consultEnhancementLineIds"] as? [String] == [])
        #expect(json["consultId"] as? String == "consult_1")
    }

    // MARK: - The two sizing windows

    @Test func availabilityAsksForTheConsultsWidthInBothWindows() async throws {
        let service = BookingService(api: await api())

        reset("""
        {"ok":true,"timeZone":"America/New_York","serviceName":null,
         "request":{"professionalId":"pro_1","serviceId":"svc_1","offeringId":"off_1",
          "locationType":"SALON","locationId":"loc_1","durationMinutes":270},
         "availableDays":[],"selectedDay":null,"offering":null}
        """)
        _ = try await service.bootstrap(
            professionalId: "pro_1", serviceId: "svc_1", offeringId: "off_1",
            consultId: "consult_1")
        #expect(try queryItems()["consultId"] == "consult_1")

        reset("""
        {"ok":true,"timeZone":"America/New_York","date":"2026-07-10","slots":[],
         "request":{"professionalId":"pro_1","serviceId":"svc_1","offeringId":"off_1",
          "locationType":"SALON","locationId":"loc_1","durationMinutes":270}}
        """)
        _ = try await service.day(
            professionalId: "pro_1", serviceId: "svc_1", offeringId: "off_1",
            locationId: "loc_1", date: "2026-07-10", consultId: "consult_1")
        #expect(try queryItems()["consultId"] == "consult_1")
    }

    @Test func anOrdinaryAvailabilityQueryCarriesNoConsultId() async throws {
        reset("""
        {"ok":true,"timeZone":"America/New_York","date":"2026-07-10","slots":[],
         "request":{"professionalId":"pro_1","serviceId":"svc_1","offeringId":"off_1",
          "locationType":"SALON","locationId":"loc_1","durationMinutes":90}}
        """)
        _ = try await BookingService(api: await api()).day(
            professionalId: "pro_1", serviceId: "svc_1", offeringId: "off_1",
            locationId: "loc_1", date: "2026-07-10")
        #expect(try queryItems()["consultId"] == nil)
    }

    // MARK: - The proposal question

    /// The mode is REQUIRED with no default, and the ids name WHICH answer is
    /// wanted. Both are query parameters because neither reserves anything.
    @Test func theProposalQuestionNamesTheModeAndTheTickedIds() async throws {
        reset(Self.proposalResponse)
        let service = ConsultService(
            api: await api(), uploadSession: .shared, supabaseURL: nil, supabaseKey: nil)

        _ = try await service.proposal(
            consultId: "consult_1", locationType: "MOBILE",
            enhancementLineIds: ["line_a", "line_b"])

        let url = try #require(ConsultWireURLProtocol.capturedURL)
        #expect(url.path.hasSuffix("/client/consult/consult_1/proposal"))
        let items = try queryItems()
        #expect(items["locationType"] == "MOBILE")
        #expect(items["enhancementIds"] == "line_a,line_b")
    }

    /// Absent means the floor alone — the parameter is omitted rather than sent
    /// empty, which is what the route reads as "she asked for nothing".
    @Test func anEmptySelectionOmitsTheParameterEntirely() async throws {
        reset(Self.proposalResponse)
        let service = ConsultService(
            api: await api(), uploadSession: .shared, supabaseURL: nil, supabaseKey: nil)

        _ = try await service.proposal(consultId: "consult_1", locationType: "SALON")

        let items = try queryItems()
        #expect(items["enhancementIds"] == nil)
        #expect(items["locationType"] == "SALON")
    }
}
