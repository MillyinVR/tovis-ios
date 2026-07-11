import Foundation
import Testing
@testable import TovisKit

// Proves the saved-address management writes hit the right routes and encode the
// PATCH/DELETE bodies the way the web Settings → Addresses card does:
//   • updateServiceAddress() → PATCH /client/addresses/{id}
//       - label/apt-only edit OMITS the address anchor (server keeps the geocoded
//         address, no re-verify) and clears a field via an explicit JSON null.
//       - a re-picked place SENDS the full anchor (formattedAddress + placeId + coords).
//   • setDefault()           → PATCH /client/addresses/{id} with ONLY { isDefault: true }
//   • delete()               → DELETE /client/addresses/{id}
//   • searchArea()           → GET, returns the DEFAULT SEARCH_AREA (discovery origin) only
//   • saveSearchArea()       → POST a default SEARCH_AREA create, then DELETE the row it replaced
// Plus the pure `mapsURL` helper (coords-first, else address text).

/// Records the outgoing request and serves a canned envelope.
final class AddressesURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedBody = request.httpBody ?? request.addressesBodyStreamData()

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
    func addressesBodyStreamData() -> Data? {
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

@Suite(.serialized) struct AddressesServiceTests {
    private func makeService() async -> AddressesService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AddressesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.addresses.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return AddressesService(api: api)
    }

    private func reset() {
        AddressesURLProtocol.capturedPath = nil
        AddressesURLProtocol.capturedMethod = nil
        AddressesURLProtocol.capturedBody = nil
        AddressesURLProtocol.status = 200
        AddressesURLProtocol.responseBody = addressEnvelope
    }

    private let addressEnvelope = Data("""
    {"address":{"id":"addr_1","kind":"SERVICE_ADDRESS","label":"Home","isDefault":true,"formattedAddress":"123 Main St, San Diego, CA 92101, USA","addressLine1":null,"addressLine2":null,"city":"San Diego","state":"CA","postalCode":"92101","countryCode":"US","placeId":"pl_1","lat":32.7,"lng":-117.1,"createdAt":"2026-07-10T00:00:00.000Z","updatedAt":"2026-07-10T00:00:00.000Z"}}
    """.utf8)

    private func decodeBody(_ data: Data?) throws -> [String: Any] {
        let body = try #require(data)
        let json = try JSONSerialization.jsonObject(with: body)
        return try #require(json as? [String: Any])
    }

    // MARK: - updateServiceAddress (label/apt/default only)

    @Test func updateWithoutPlaceOmitsAnchorAndPatchesById() async throws {
        reset()

        let updated = try await makeService().updateServiceAddress(
            id: "addr_1",
            label: "Home",
            apt: "4B",
            isDefault: true
        )

        #expect(AddressesURLProtocol.capturedPath == "/api/v1/client/addresses/addr_1")
        #expect(AddressesURLProtocol.capturedMethod == "PATCH")

        let sent = try decodeBody(AddressesURLProtocol.capturedBody)
        #expect(sent["label"] as? String == "Home")
        #expect(sent["addressLine2"] as? String == "4B")
        #expect(sent["isDefault"] as? Bool == true)

        // A label/apt-only edit must NOT send the geocoded anchor — otherwise the
        // server would re-verify (or clear) the resolved address.
        #expect(sent["formattedAddress"] == nil)
        #expect(sent["placeId"] == nil)
        #expect(sent["lat"] == nil)
        #expect(sent["lng"] == nil)
        #expect(sent["city"] == nil)

        #expect(updated.id == "addr_1")
        #expect(updated.isDefault)
    }

    @Test func updateSendsExplicitNullsToClearLabelAndApt() async throws {
        reset()

        _ = try await makeService().updateServiceAddress(
            id: "addr_1",
            label: nil,
            apt: nil,
            isDefault: false
        )

        let sent = try decodeBody(AddressesURLProtocol.capturedBody)
        // Present + explicitly null (not omitted) so the backend clears the field.
        #expect(sent.keys.contains("label"))
        #expect(sent.keys.contains("addressLine2"))
        #expect(sent["label"] is NSNull)
        #expect(sent["addressLine2"] is NSNull)
        #expect(sent["isDefault"] as? Bool == false)
    }

    // MARK: - updateServiceAddress (re-picked place)

    @Test func updateWithPlaceSendsFullAnchor() async throws {
        reset()

        let place = PlaceDetails(
            placeId: "pl_new",
            formattedAddress: "500 Market St, San Francisco, CA 94105, USA",
            lat: 37.79,
            lng: -122.4,
            city: "San Francisco",
            state: "CA",
            postalCode: "94105",
            countryCode: "US"
        )

        _ = try await makeService().updateServiceAddress(
            id: "addr_1",
            label: "Work",
            apt: nil,
            isDefault: false,
            place: place
        )

        let sent = try decodeBody(AddressesURLProtocol.capturedBody)
        #expect(sent["label"] as? String == "Work")
        #expect(sent["formattedAddress"] as? String == "500 Market St, San Francisco, CA 94105, USA")
        #expect(sent["placeId"] as? String == "pl_new")
        #expect(sent["city"] as? String == "San Francisco")
        #expect(sent["state"] as? String == "CA")
        #expect(sent["postalCode"] as? String == "94105")
        #expect(sent["countryCode"] as? String == "US")
        #expect((sent["lat"] as? Double) == 37.79)
        #expect((sent["lng"] as? Double) == -122.4)
    }

    // MARK: - setDefault

    @Test func setDefaultPatchesOnlyIsDefault() async throws {
        reset()

        _ = try await makeService().setDefault(id: "addr_2")

        #expect(AddressesURLProtocol.capturedPath == "/api/v1/client/addresses/addr_2")
        #expect(AddressesURLProtocol.capturedMethod == "PATCH")

        let sent = try decodeBody(AddressesURLProtocol.capturedBody)
        // Only the default flag — every other field is omitted so the server keeps
        // the address untouched and just promotes this row.
        #expect(sent.count == 1)
        #expect(sent["isDefault"] as? Bool == true)
    }

    // MARK: - delete

    @Test func deleteHitsDeleteRoute() async throws {
        reset()
        AddressesURLProtocol.responseBody = Data("{\"deleted\":true,\"id\":\"addr_1\"}".utf8)

        try await makeService().delete(id: "addr_1")

        #expect(AddressesURLProtocol.capturedPath == "/api/v1/client/addresses/addr_1")
        #expect(AddressesURLProtocol.capturedMethod == "DELETE")
    }

    // MARK: - searchArea (discovery origin)

    @Test func searchAreaReturnsDefaultSearchAreaOnly() async throws {
        reset()
        // A mix: a service address + two search areas (one default). searchArea()
        // must return the DEFAULT search area — never the service address.
        AddressesURLProtocol.responseBody = Data("""
        {"addresses":[
          {"id":"svc_1","kind":"SERVICE_ADDRESS","label":"Home","isDefault":true,"formattedAddress":"123 Main St","addressLine1":null,"addressLine2":null,"city":"San Diego","state":"CA","postalCode":"92101","countryCode":"US","placeId":"pl_svc","lat":32.7,"lng":-117.1,"createdAt":"2026-07-10T00:00:00.000Z","updatedAt":"2026-07-10T00:00:00.000Z"},
          {"id":"area_2","kind":"SEARCH_AREA","label":null,"isDefault":false,"formattedAddress":"Los Angeles, CA, USA","addressLine1":null,"addressLine2":null,"city":"Los Angeles","state":"CA","postalCode":null,"countryCode":"US","placeId":"pl_la","lat":34.05,"lng":-118.24,"createdAt":"2026-07-09T00:00:00.000Z","updatedAt":"2026-07-09T00:00:00.000Z"},
          {"id":"area_1","kind":"SEARCH_AREA","label":null,"isDefault":true,"formattedAddress":"San Diego, CA, USA","addressLine1":null,"addressLine2":null,"city":"San Diego","state":"CA","postalCode":null,"countryCode":"US","placeId":"pl_sd","lat":32.7157,"lng":-117.1611,"createdAt":"2026-07-10T00:00:00.000Z","updatedAt":"2026-07-10T00:00:00.000Z"}
        ]}
        """.utf8)

        let area = try await makeService().searchArea()

        #expect(AddressesURLProtocol.capturedPath == "/api/v1/client/addresses")
        #expect(AddressesURLProtocol.capturedMethod == "GET")
        #expect(area?.id == "area_1")
        #expect(area?.isSearchArea == true)
        #expect(area?.isDefault == true)
    }

    @Test func searchAreaNilWhenNoneSaved() async throws {
        reset()
        AddressesURLProtocol.responseBody = Data("""
        {"addresses":[{"id":"svc_1","kind":"SERVICE_ADDRESS","label":"Home","isDefault":true,"formattedAddress":"123 Main St","addressLine1":null,"addressLine2":null,"city":"San Diego","state":"CA","postalCode":"92101","countryCode":"US","placeId":"pl_svc","lat":32.7,"lng":-117.1,"createdAt":"2026-07-10T00:00:00.000Z","updatedAt":"2026-07-10T00:00:00.000Z"}]}
        """.utf8)

        let area = try await makeService().searchArea()
        #expect(area == nil)
    }

    // MARK: - saveSearchArea (discovery origin from a picked AREA)

    @Test func saveSearchAreaPostsSearchAreaCreate() async throws {
        reset()   // POST returns the default addressEnvelope (id addr_1)

        let place = PlaceDetails(
            placeId: "pl_sd",
            formattedAddress: "San Diego, CA, USA",
            lat: 32.7157,
            lng: -117.1611,
            city: "San Diego",
            state: "CA",
            postalCode: nil,
            countryCode: "US"
        )

        let saved = try await makeService().saveSearchArea(from: place)

        #expect(AddressesURLProtocol.capturedPath == "/api/v1/client/addresses")
        #expect(AddressesURLProtocol.capturedMethod == "POST")

        let sent = try decodeBody(AddressesURLProtocol.capturedBody)
        #expect(sent["kind"] as? String == "SEARCH_AREA")
        // A fresh discovery origin is always the default for its kind.
        #expect(sent["isDefault"] as? Bool == true)
        #expect(sent["formattedAddress"] as? String == "San Diego, CA, USA")
        #expect(sent["placeId"] as? String == "pl_sd")
        #expect(sent["city"] as? String == "San Diego")
        #expect(sent["state"] as? String == "CA")
        #expect(sent["countryCode"] as? String == "US")
        #expect((sent["lat"] as? Double) == 32.7157)
        #expect((sent["lng"] as? Double) == -117.1611)
        // An AREA pick carries no street line / apt (keys omitted, not null).
        #expect(sent["addressLine1"] == nil)
        #expect(sent["addressLine2"] == nil)
        #expect(saved.id == "addr_1")
    }

    @Test func saveSearchAreaReplacingDeletesPriorRow() async throws {
        reset()   // POST returns id addr_1; the follow-up DELETE reuses the same body (void)

        let place = PlaceDetails(
            placeId: "pl_sd",
            formattedAddress: "San Diego, CA, USA",
            lat: 32.7157,
            lng: -117.1611,
            city: "San Diego",
            state: "CA",
            postalCode: nil,
            countryCode: "US"
        )

        // The prior row id differs from the created id, so the cleanup DELETE fires.
        _ = try await makeService().saveSearchArea(from: place, replacing: "area_old")

        // The LAST request the mock saw is the cleanup DELETE of the superseded row.
        #expect(AddressesURLProtocol.capturedPath == "/api/v1/client/addresses/area_old")
        #expect(AddressesURLProtocol.capturedMethod == "DELETE")
    }

    // MARK: - mapsURL helper (pure)

    @Test func mapsURLPrefersCoordinates() {
        let address = ClientAddress(
            id: "a", kind: "SERVICE_ADDRESS", label: "Home", isDefault: true,
            formattedAddress: "123 Main St", addressLine1: nil, addressLine2: nil,
            city: "San Diego", state: "CA", postalCode: "92101", countryCode: "US",
            placeId: "pl_1", lat: 32.7, lng: -117.1,
            createdAt: "2026-07-10T00:00:00.000Z", updatedAt: "2026-07-10T00:00:00.000Z"
        )

        let url = try? #require(address.mapsURL)
        let string = url?.absoluteString ?? ""
        #expect(string.contains("32.7"))
        #expect(string.contains("117.1"))
    }

    @Test func mapsURLFallsBackToAddressText() {
        let address = ClientAddress(
            id: "a", kind: "SERVICE_ADDRESS", label: nil, isDefault: false,
            formattedAddress: "123 Main St, San Diego", addressLine1: nil, addressLine2: nil,
            city: nil, state: nil, postalCode: nil, countryCode: nil,
            placeId: nil, lat: nil, lng: nil,
            createdAt: "2026-07-10T00:00:00.000Z", updatedAt: "2026-07-10T00:00:00.000Z"
        )

        let url = try? #require(address.mapsURL)
        #expect(url?.absoluteString.contains("query=123") == true)
    }
}
