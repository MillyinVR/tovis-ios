import Foundation
import Testing
@testable import TovisKit

// W6 — the add-service create must not IMPOSE a location mode.
//
// `createOffering` used to take two non-optional Bools and always put both on
// the wire, and the iOS form filled them with a hardcoded `true`/`false`. So a
// mobile-only pro adding a service on the phone wrote `offersInSalon: true`,
// straight past the server-side derivation in `POST /api/v1/pro/offerings` —
// which only derives a flag that was OMITTED. Their client-facing booking drawer
// then showed an In-salon toggle (and the salon waitlist under it) for a pro who
// only travels.
//
// These prove the wire shape the fix depends on: an unstated mode is ABSENT from
// the JSON body, and a stated one is present with exactly the pro's choice.

/// Records the outgoing request and serves a canned offering envelope.
final class ProOfferingCreateURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedBody = request.httpBody ?? request.offeringCreateBodyStreamData()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 201, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.cannedOffering)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A mobile-only offering, i.e. what the server derives for this pro.
    static let cannedOffering = Data(
        """
        {"ok":true,"offering":{
          "id":"off_new","serviceId":"svc_balayage","description":null,
          "customImageUrl":null,"offersInSalon":false,"offersMobile":true,
          "salonPriceStartingAt":null,"salonDurationMinutes":null,
          "mobilePriceStartingAt":"180.00","mobileDurationMinutes":180,
          "rebookIntervalDays":null,"isActive":true,"serviceName":"Balayage",
          "categoryName":"Hair","serviceDefaultImageUrl":null,"minPrice":"180.00"
        }}
        """.utf8
    )
}

private extension URLRequest {
    func offeringCreateBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ProOfferingCreateModesTests {
    private func makeService() async -> ProProfileService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProOfferingCreateURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.offeringcreate.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProProfileService(api: api)
    }

    private func reset() {
        ProOfferingCreateURLProtocol.capturedPath = nil
        ProOfferingCreateURLProtocol.capturedMethod = nil
        ProOfferingCreateURLProtocol.capturedBody = nil
    }

    private func bodyJSON() throws -> [String: Any] {
        let body = try #require(ProOfferingCreateURLProtocol.capturedBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// THE regression. Modes left unstated ⇒ neither key on the wire, so the
    /// route derives them from the pro's bookable locations.
    @Test func createOfferingOmitsUnstatedModes() async throws {
        reset()
        _ = try await makeService().createOffering(
            serviceId: "svc_balayage",
            description: nil,
            customImageUrl: nil,
            salonPriceStartingAt: "180.00",
            salonDurationMinutes: 180,
            mobilePriceStartingAt: "180.00",
            mobileDurationMinutes: 180
        )

        #expect(ProOfferingCreateURLProtocol.capturedPath == "/api/v1/pro/offerings")
        #expect(ProOfferingCreateURLProtocol.capturedMethod == "POST")

        let json = try bodyJSON()
        #expect(json["serviceId"] as? String == "svc_balayage")
        // ABSENT — not `false`, and not JSON `null` either. The route keys its
        // derivation on `hasOwnProperty`, so an explicit null would be read as a
        // stated-but-invalid flag and 400 rather than deriving.
        #expect(json["offersInSalon"] == nil)
        #expect(json["offersMobile"] == nil)
        // Pricing for BOTH rides along, so whichever mode the server derives has
        // the price and duration it then demands.
        #expect(json["salonPriceStartingAt"] as? String == "180.00")
        #expect(json["mobilePriceStartingAt"] as? String == "180.00")
    }

    /// A mobile-only pro whose form seeded from `defaultOfferingModes` and who
    /// then touched a toggle: the choice goes over verbatim, salon explicitly off.
    @Test func createOfferingSendsStatedMobileOnlyModes() async throws {
        reset()
        _ = try await makeService().createOffering(
            serviceId: "svc_balayage",
            description: nil,
            customImageUrl: nil,
            offersInSalon: false,
            offersMobile: true,
            salonPriceStartingAt: nil,
            salonDurationMinutes: nil,
            mobilePriceStartingAt: "180.00",
            mobileDurationMinutes: 180
        )

        let json = try bodyJSON()
        #expect(json["offersInSalon"] as? Bool == false)
        #expect(json["offersMobile"] as? Bool == true)
        // Present-as-null, not absent: the price fields always ship (`stringOrNull`),
        // and only the MODE flags use omission to mean "not stated".
        #expect(json["salonPriceStartingAt"] is NSNull)
        #expect(json["mobileDurationMinutes"] as? Int == 180)
    }

    /// One mode stated, the other left to the server — the two are independent.
    @Test func createOfferingSendsOnlyTheStatedMode() async throws {
        reset()
        _ = try await makeService().createOffering(
            serviceId: "svc_balayage",
            description: nil,
            customImageUrl: nil,
            offersMobile: true,
            salonPriceStartingAt: "180.00",
            salonDurationMinutes: 180,
            mobilePriceStartingAt: "180.00",
            mobileDurationMinutes: 180
        )

        let json = try bodyJSON()
        #expect(json["offersInSalon"] == nil)
        #expect(json["offersMobile"] as? Bool == true)
    }
}
