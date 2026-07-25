import Foundation
import Testing

@testable import TovisKit

// B1-A — the add-on selection has to reach the OFFER and the RESERVATION, not
// just the commit.
//
// Finalize has always enforced `base + add-ons`. Until this card, `addOnIds`
// went ONLY to finalize: `/availability/day` was asked for the base service and
// `POST /holds` had no such field at all, so a client who ticked a 30-minute
// add-on was offered starts that did not fit and held a window narrower than the
// booking they were about to make. Two consequences, both driven server-side:
// the un-held tail could be taken by someone else, and the last starts of every
// working day dead-ended at the end of checkout.
//
// This flow knows the selection before the time is picked, so both calls now
// carry it. These pin what actually goes on the wire — a passing decode test
// would not have caught the omission, because the omission was in the REQUEST.

private final class AddOnWireURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var capturedURL: URL?
    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedURL = request.url
        // URLProtocol strips httpBody for a streamed upload; read the stream.
        Self.capturedBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }

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
struct AddOnWindowWireTests {
    private func makeService() async -> BookingService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AddOnWireURLProtocol.self]
        let tokenStore = TokenStore(service: "me.tovis.app.session.addonwire.tests")
        await tokenStore.save("session.token.value")
        return BookingService(api: APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: URLSession(configuration: configuration),
            tokenStore: tokenStore
        ))
    }

    private func capturedQuery() throws -> [String: String] {
        let url = try #require(AddOnWireURLProtocol.capturedURL)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func capturedJSONBody() throws -> [String: Any] {
        let data = try #require(AddOnWireURLProtocol.capturedBody)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    @Test("a day request carries the selected add-ons, so the OFFER is sized for them")
    func daySendsAddOnIds() async throws {
        AddOnWireURLProtocol.body = try fixture("availabilityDay")
        _ = try await makeService().day(
            professionalId: "pro_1", serviceId: "svc_1", offeringId: "off_1",
            locationId: "loc_1", durationMinutes: 60, date: "2026-08-04",
            locationType: "SALON", clientAddressId: nil,
            addOnIds: ["addon_2", "addon_1"]
        )

        // Sorted so the same selection produces the same URL — the server sorts
        // the ids too, and the day response is cached on them.
        #expect(try capturedQuery()["addOnIds"] == "addon_1,addon_2")
    }

    @Test("no add-ons means no param at all, not an empty one")
    func daySendsNoAddOnParamWhenNoneSelected() async throws {
        AddOnWireURLProtocol.body = try fixture("availabilityDay")
        _ = try await makeService().day(
            professionalId: "pro_1", serviceId: "svc_1", offeringId: "off_1",
            locationId: "loc_1", durationMinutes: 60, date: "2026-08-04"
        )

        #expect(try capturedQuery()["addOnIds"] == nil)
    }

    @Test("a hold carries the selected add-ons, so the RESERVATION covers them")
    func createHoldSendsAddOnIds() async throws {
        AddOnWireURLProtocol.body = try fixture("bookingHoldCreate")
        let hold = try await makeService().createHold(
            offeringId: "off_1", locationId: "loc_1",
            scheduledFor: "2026-08-04T20:00:00.000Z", locationType: "SALON",
            clientAddressId: nil, source: "REQUESTED",
            addOnIds: ["addon_1"]
        )

        let body = try capturedJSONBody()
        #expect(body["addOnIds"] as? [String] == ["addon_1"])

        // And the server answers with what it actually reserved.
        #expect(hold.durationMinutes == 90)
    }

    @Test("a hold with no add-ons still states the empty selection explicitly")
    func createHoldSendsEmptyAddOnIds() async throws {
        AddOnWireURLProtocol.body = try fixture("bookingHoldCreate")
        _ = try await makeService().createHold(
            offeringId: "off_1", locationId: "loc_1",
            scheduledFor: "2026-08-04T20:00:00.000Z"
        )

        let body = try capturedJSONBody()
        #expect(body["addOnIds"] as? [String] == [])
    }
}
