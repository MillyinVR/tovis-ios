import Foundation
import Testing
@testable import TovisKit

// Proves the pro add-ons SAVE does not quietly reset settings it does not own.
//
// `PUT /pro/offerings/{id}/add-ons` is a REPLACE, not a merge: the route deletes
// every row for the offering and recreates the set from the payload, so a field
// the client leaves out is not "unchanged" — it comes back as the route's own
// default (isActive true, isRecommended false, the three overrides null). The
// add-ons screen only toggles MEMBERSHIP, so every other field on a row it did
// not create has to be echoed back verbatim.
//
// The field that bites in practice is `isRecommended`: web sets it from a
// per-add-on pill, and clients see it both as a "Recommended" badge and as their
// DEFAULT SELECTION in the booking flow — so silently clearing it changes what a
// client arrives pre-checked with, not just a label.
//
// Covered here:
//   • replacementSet echoes an existing row verbatim (all seven fields)
//   • newly switched-on services get route defaults and sort AFTER existing rows
//   • switched-off services drop out
//   • the actual PUT wire body carries isRecommended — pinned off the request,
//     not off the model, so a re-encoding change cannot pass by accident
//   • saveAddOns THROWS on a rejection, which is what the view now surfaces

/// Records the outgoing request and serves a canned envelope.
final class ProAddOnsSaveURLProtocol: URLProtocol {
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
        Self.capturedBody = request.httpBody ?? request.addOnsSaveBodyStreamData()

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
    func addOnsSaveBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ProAddOnsSaveTests {

    // The server's current rows, decoded from the same shape GET returns rather
    // than hand-built, so the test is pinned to the wire and not to the model.
    private func attachedRows() throws -> [String: ProAddOnAttached] {
        let json = Data("""
        {
          "eligible": [],
          "attached": [
            {
              "id": "addon_2",
              "addOnServiceId": "svc_gloss",
              "title": "Gloss",
              "group": "COLOR",
              "isActive": true,
              "isRecommended": true,
              "sortOrder": 10,
              "locationType": "SALON",
              "priceOverride": "45.00",
              "durationOverrideMinutes": 25
            }
          ]
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(ProAddOns.self, from: json)
        return Dictionary(
            decoded.attached.map { ($0.addOnServiceId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func makeService() async -> ProProfileService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProAddOnsSaveURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.addonssave.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProProfileService(api: api)
    }

    // THE REGRESSION. Re-saving an untouched, already-attached row must echo it
    // back exactly — before the fix this rebuilt every row from defaults, so a
    // pro who opened Add-ons and tapped Save un-recommended their own add-ons.
    @Test func preservesAnExistingRowVerbatim() throws {
        let items = ProAddOnInput.replacementSet(
            eligibleOrder: ["svc_gloss"],
            attached: ["svc_gloss"],
            existing: try attachedRows()
        )

        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.addOnServiceId == "svc_gloss")
        #expect(item.isRecommended == true)
        #expect(item.isActive == true)
        #expect(item.sortOrder == 10)
        #expect(item.locationType == "SALON")
        #expect(item.priceOverride == "45.00")
        #expect(item.durationOverrideMinutes == 25)
    }

    // A service the pro just switched on has no server row, so it takes the
    // route's defaults — and sorts after everything that already had an order
    // rather than renumbering the pro's arrangement.
    @Test func newRowsTakeDefaultsAndSortAfterExistingOnes() throws {
        let items = ProAddOnInput.replacementSet(
            eligibleOrder: ["svc_toner", "svc_gloss"],
            attached: ["svc_toner", "svc_gloss"],
            existing: try attachedRows()
        )

        #expect(items.count == 2)
        // Order follows the eligible library, not the sort orders.
        #expect(items.map(\.addOnServiceId) == ["svc_toner", "svc_gloss"])

        let fresh = try #require(items.first { $0.addOnServiceId == "svc_toner" })
        #expect(fresh.isActive == true)
        #expect(fresh.isRecommended == false)
        #expect(fresh.locationType == nil)
        #expect(fresh.priceOverride == nil)
        #expect(fresh.durationOverrideMinutes == nil)
        // 10 is the highest existing sortOrder, so the new row lands at 11 and
        // the preserved row keeps its own.
        #expect(fresh.sortOrder == 11)
        #expect(items.first { $0.addOnServiceId == "svc_gloss" }?.sortOrder == 10)
    }

    // Switching a service off drops it from the payload, which is what makes the
    // route delete it. Membership is still the thing this screen owns.
    @Test func switchedOffServicesDropOut() throws {
        let items = ProAddOnInput.replacementSet(
            eligibleOrder: ["svc_toner", "svc_gloss"],
            attached: ["svc_toner"],
            existing: try attachedRows()
        )

        #expect(items.map(\.addOnServiceId) == ["svc_toner"])
    }

    // An empty selection sends an empty set — the route reads that as "detach
    // everything", so it must not be confused with "nothing to do".
    @Test func emptySelectionSendsAnEmptySet() throws {
        let items = ProAddOnInput.replacementSet(
            eligibleOrder: ["svc_toner", "svc_gloss"],
            attached: [],
            existing: try attachedRows()
        )

        #expect(items.isEmpty)
    }

    // Pins the actual bytes on the wire: isRecommended has to reach the server as
    // true. Asserting on the model alone would not catch an encoding regression.
    @Test func putBodyCarriesPreservedFlags() async throws {
        let service = await makeService()
        ProAddOnsSaveURLProtocol.status = 200
        ProAddOnsSaveURLProtocol.capturedBody = nil

        let items = ProAddOnInput.replacementSet(
            eligibleOrder: ["svc_gloss"],
            attached: ["svc_gloss"],
            existing: try attachedRows()
        )
        try await service.saveAddOns(offeringId: "off_1", items: items)

        #expect(ProAddOnsSaveURLProtocol.capturedMethod == "PUT")
        #expect(ProAddOnsSaveURLProtocol.capturedPath == "/api/v1/pro/offerings/off_1/add-ons")

        let body = try #require(ProAddOnsSaveURLProtocol.capturedBody)
        let parsed = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let sent = try #require(parsed?["items"] as? [[String: Any]])
        #expect(sent.count == 1)
        let first = try #require(sent.first)
        #expect(first["addOnServiceId"] as? String == "svc_gloss")
        #expect(first["isRecommended"] as? Bool == true)
        #expect(first["isActive"] as? Bool == true)
        #expect(first["sortOrder"] as? Int == 10)
        #expect(first["locationType"] as? String == "SALON")
        #expect(first["priceOverride"] as? String == "45.00")
        #expect(first["durationOverrideMinutes"] as? Int == 25)
    }

    // A rejected save has to THROW so the view can surface it. The bug this card
    // filed was `catch { banner = nil }` swallowing exactly this.
    @Test func rejectedSaveThrows() async throws {
        let service = await makeService()
        ProAddOnsSaveURLProtocol.status = 400
        ProAddOnsSaveURLProtocol.responseBody = Data(
            "{\"ok\":false,\"error\":{\"message\":\"One or more selected add-on services are invalid or not add-on eligible.\"}}".utf8
        )
        defer {
            ProAddOnsSaveURLProtocol.status = 200
            ProAddOnsSaveURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
        }

        await #expect(throws: (any Error).self) {
            try await service.saveAddOns(offeringId: "off_1", items: [])
        }
    }
}
