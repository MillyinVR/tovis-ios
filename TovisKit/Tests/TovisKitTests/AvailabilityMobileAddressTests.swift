import Foundation
import Testing

@testable import TovisKit

// A MOBILE placement is computed against the CLIENT's address — the pro's travel
// radius FROM it — so `clientAddressId` is a required input, not a refinement.
// Server-side `validateAvailabilityPlacement` refuses a MOBILE request without it
// (`CLIENT_SERVICE_ADDRESS_REQUIRED`, HTTP 400) on BOTH /availability/bootstrap and
// /availability/day, so an omitted param is a dead-ended booking flow, never a
// silently-less-accurate slot list. Verified against `pnpm dev` on 2026-07-22:
//   bootstrap?…&locationType=MOBILE                     → 400 CLIENT_SERVICE_ADDRESS_REQUIRED
//   bootstrap?…&locationType=MOBILE&clientAddressId=…   → 200
// These pin the query the client actually puts on the wire.

private final class AvailabilityURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var capturedURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedURL = request.url
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct AvailabilityMobileAddressTests {
    private func makeService() async -> BookingService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AvailabilityURLProtocol.self]
        let tokenStore = TokenStore(service: "me.tovis.app.session.availability.tests")
        await tokenStore.save("session.token.value")
        return BookingService(api: APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: URLSession(configuration: configuration),
            tokenStore: tokenStore
        ))
    }

    /// The captured query as a dictionary — order is the URLComponents' business.
    private func capturedQuery() throws -> [String: String] {
        let url = try #require(AvailabilityURLProtocol.capturedURL)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("a MOBILE bootstrap carries the client's service address")
    func mobileBootstrapSendsAddress() async throws {
        AvailabilityURLProtocol.body = try fixture("availabilityBootstrap")
        _ = try await makeService().bootstrap(
            professionalId: "pro_1", serviceId: "svc_1", offeringId: "off_1",
            durationMinutes: 75, locationType: "MOBILE", clientAddressId: "addr_1"
        )

        let query = try capturedQuery()
        #expect(query["locationType"] == "MOBILE")
        #expect(query["clientAddressId"] == "addr_1")
    }

    @Test("a SALON bootstrap sends no address — the server nils it there anyway")
    func salonBootstrapOmitsAddress() async throws {
        AvailabilityURLProtocol.body = try fixture("availabilityBootstrap")
        _ = try await makeService().bootstrap(
            professionalId: "pro_1", serviceId: "svc_1", offeringId: "off_1",
            durationMinutes: 60, locationType: "SALON"
        )

        let query = try capturedQuery()
        #expect(query["locationType"] == "SALON")
        #expect(query["clientAddressId"] == nil)
    }

    /// An empty string is not an address: sending `clientAddressId=` would fail the
    /// server's own trim-to-nil check instead of being treated as "not provided".
    @Test("an empty address id is omitted rather than sent blank")
    func emptyAddressIdIsOmitted() async throws {
        AvailabilityURLProtocol.body = try fixture("availabilityBootstrap")
        _ = try await makeService().bootstrap(
            professionalId: "pro_1", serviceId: "svc_1", offeringId: "off_1",
            durationMinutes: 75, locationType: "MOBILE", clientAddressId: ""
        )

        #expect(try capturedQuery()["clientAddressId"] == nil)
    }

    @Test("a MOBILE day request carries the same address the hold will use")
    func mobileDaySendsAddress() async throws {
        AvailabilityURLProtocol.body = try fixture("availabilityDay")
        _ = try await makeService().day(
            professionalId: "pro_1", serviceId: "svc_1", offeringId: "off_1",
            locationId: "loc_1", durationMinutes: 75, date: "2026-07-22",
            locationType: "MOBILE", clientAddressId: "addr_1"
        )

        let query = try capturedQuery()
        #expect(query["locationType"] == "MOBILE")
        #expect(query["date"] == "2026-07-22")
        #expect(query["clientAddressId"] == "addr_1")
    }
}
