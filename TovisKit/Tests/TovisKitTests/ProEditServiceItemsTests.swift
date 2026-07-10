import Foundation
import Testing
@testable import TovisKit

// Proves the two halves of the pro "edit the services on a booking" flow:
//   • ProBookingService.editServiceItems PATCHes /pro/bookings/{id} as an
//     authenticated native request, carrying a minimal {serviceId, offeringId,
//     sortOrder} per item + notifyClient, with an idempotency-key header.
//   • ProBookingService.sellableServices GETs /pro/services?locationType= and
//     decodes the flat picker rows (id == serviceId, offeringId, selectedMode).

/// Records the outgoing request and serves a canned envelope.
final class ProEditServiceItemsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedQuery: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedAuthHeader: String?
    nonisolated(unsafe) static var capturedNativeHeader: String?
    nonisolated(unsafe) static var capturedIdempotencyKey: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedQuery = request.url?.query
        Self.capturedMethod = request.httpMethod
        Self.capturedAuthHeader = request.value(forHTTPHeaderField: "Authorization")
        Self.capturedNativeHeader = request.value(forHTTPHeaderField: "x-tovis-native")
        Self.capturedIdempotencyKey = request.value(forHTTPHeaderField: "idempotency-key")
        // URLProtocol strips httpBody into httpBodyStream; read whichever is set.
        Self.capturedBody = request.httpBody ?? request.bodyStreamData()

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
    func bodyStreamData() -> Data? {
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

@Suite(.serialized) struct ProEditServiceItemsTests {
    private func makeService() async -> ProBookingService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProEditServiceItemsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.editserviceitems.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProBookingService(api: api)
    }

    private func reset(_ body: String) {
        ProEditServiceItemsURLProtocol.capturedPath = nil
        ProEditServiceItemsURLProtocol.capturedQuery = nil
        ProEditServiceItemsURLProtocol.capturedMethod = nil
        ProEditServiceItemsURLProtocol.capturedAuthHeader = nil
        ProEditServiceItemsURLProtocol.capturedNativeHeader = nil
        ProEditServiceItemsURLProtocol.capturedIdempotencyKey = nil
        ProEditServiceItemsURLProtocol.capturedBody = nil
        ProEditServiceItemsURLProtocol.status = 200
        ProEditServiceItemsURLProtocol.responseBody = Data(body.utf8)
    }

    @Test func patchesServiceItemsAsAuthenticatedNativeRequestWithIdempotencyKey() async throws {
        reset("""
        {"ok":true,"booking":{"id":"bkg_1","status":"ACCEPTED"},"meta":{"mutated":true,"noOp":false}}
        """)

        try await makeService().editServiceItems(
            bookingId: "bkg_1",
            items: [
                ProBookingServiceItemInput(serviceId: "svc_base", offeringId: "off_base", sortOrder: 0),
                ProBookingServiceItemInput(serviceId: "svc_addon", offeringId: "off_addon", sortOrder: 1),
            ],
            notifyClient: true
        )

        #expect(ProEditServiceItemsURLProtocol.capturedPath == "/api/v1/pro/bookings/bkg_1")
        #expect(ProEditServiceItemsURLProtocol.capturedMethod == "PATCH")
        #expect(ProEditServiceItemsURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(ProEditServiceItemsURLProtocol.capturedNativeHeader == "ios")
        #expect((ProEditServiceItemsURLProtocol.capturedIdempotencyKey ?? "").isEmpty == false)

        let body = try #require(ProEditServiceItemsURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["notifyClient"] as? Bool == true)
        // Only the minimal per-item pair — no price/duration/name/itemType leaks.
        let items = try #require(json["serviceItems"] as? [[String: Any]])
        #expect(items.count == 2)
        #expect(items[0]["serviceId"] as? String == "svc_base")
        #expect(items[0]["offeringId"] as? String == "off_base")
        #expect(items[0]["sortOrder"] as? Int == 0)
        #expect(items[1]["serviceId"] as? String == "svc_addon")
        #expect(items[1]["sortOrder"] as? Int == 1)
        #expect(items[0]["price"] == nil)
        #expect(items[0]["durationMinutes"] == nil)
        #expect(items[0]["itemType"] == nil)
    }

    @Test func editServiceItemsKeyTracksBody() async throws {
        // Same items ⇒ same key (stable retry); a changed item set ⇒ a fresh key.
        reset("""
        {"ok":true,"booking":{"id":"bkg_1","status":"ACCEPTED"},"meta":{"mutated":true,"noOp":false}}
        """)
        try await makeService().editServiceItems(
            bookingId: "bkg_1",
            items: [ProBookingServiceItemInput(serviceId: "s1", offeringId: "o1", sortOrder: 0)]
        )
        let firstKey = try #require(ProEditServiceItemsURLProtocol.capturedIdempotencyKey)

        reset("""
        {"ok":true,"booking":{"id":"bkg_1","status":"ACCEPTED"},"meta":{"mutated":true,"noOp":false}}
        """)
        try await makeService().editServiceItems(
            bookingId: "bkg_1",
            items: [ProBookingServiceItemInput(serviceId: "s1", offeringId: "o1", sortOrder: 0)]
        )
        #expect(ProEditServiceItemsURLProtocol.capturedIdempotencyKey == firstKey)

        reset("""
        {"ok":true,"booking":{"id":"bkg_1","status":"ACCEPTED"},"meta":{"mutated":true,"noOp":false}}
        """)
        try await makeService().editServiceItems(
            bookingId: "bkg_1",
            items: [
                ProBookingServiceItemInput(serviceId: "s1", offeringId: "o1", sortOrder: 0),
                ProBookingServiceItemInput(serviceId: "s2", offeringId: "o2", sortOrder: 1),
            ]
        )
        #expect(ProEditServiceItemsURLProtocol.capturedIdempotencyKey != firstKey)
    }

    @Test func sellableServicesGetsScopedListAndDecodes() async throws {
        reset("""
        {"ok":true,"locationType":"SALON","services":[
          {"id":"svc_1","name":"Balayage","offeringId":"off_1","supportedLocationTypes":["SALON"],"selectedLocationType":"SALON","requiresLocationTypeSelection":false,"selectedMode":{"locationType":"SALON","durationMinutes":120,"priceStartingAt":"180.00"}},
          {"id":"svc_2","name":"Gloss","offeringId":"off_2","supportedLocationTypes":["SALON","MOBILE"],"selectedLocationType":"SALON","requiresLocationTypeSelection":false,"selectedMode":{"locationType":"SALON","durationMinutes":45,"priceStartingAt":"60.00"}}
        ]}
        """)

        let services = try await makeService().sellableServices(locationType: "SALON")

        #expect(ProEditServiceItemsURLProtocol.capturedPath == "/api/v1/pro/services")
        #expect(ProEditServiceItemsURLProtocol.capturedMethod == "GET")
        #expect(ProEditServiceItemsURLProtocol.capturedQuery == "locationType=SALON")

        #expect(services.count == 2)
        #expect(services[0].serviceId == "svc_1")          // id aliases serviceId
        #expect(services[0].offeringId == "off_1")
        #expect(services[0].name == "Balayage")
        #expect(services[0].selectedMode?.durationMinutes == 120)
        #expect(services[0].selectedMode?.priceStartingAt == "180.00")
        #expect(services[1].selectedMode?.priceStartingAt == "60.00")
    }
}
