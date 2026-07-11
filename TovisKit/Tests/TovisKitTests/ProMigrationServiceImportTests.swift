import Foundation
import Testing
@testable import TovisKit

// Proves the migration wizard's services-import methods hit the right routes with
// the right verbs + bodies and decode the preview/commit envelopes (existing web
// routes, POST-only, no DTO — an iOS-only port):
//   • previewServiceImport → POST /pro/migrate/services/preview { rows }
//                            → { catalog, rows }
//   • commitServiceImport  → POST /pro/migrate/services/commit  { decisions }
//                            → { rows, summary }
//   • 404 while ENABLE_PRO_MIGRATION is off → APIError.server(404) (build-dark)
// Plus the pure on-device CSV helpers (column detection + number parsing).

/// Records the outgoing request (incl. POST body) and serves a canned envelope.
final class ServiceImportURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedAuthHeader: String?
    nonisolated(unsafe) static var capturedNativeHeader: String?
    nonisolated(unsafe) static var capturedContentType: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedAuthHeader = request.value(forHTTPHeaderField: "Authorization")
        Self.capturedNativeHeader = request.value(forHTTPHeaderField: "x-tovis-native")
        Self.capturedContentType = request.value(forHTTPHeaderField: "Content-Type")
        Self.capturedBody = request.httpBody ?? request.serviceImportBodyStreamData()

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
    /// URLSession moves a POST body onto `httpBodyStream`; drain it for assertions.
    func serviceImportBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ProMigrationServiceImportTests {
    private func makeService() async -> ProMigrationService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServiceImportURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.serviceimport.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProMigrationService(api: api)
    }

    private func reset(response: String) {
        ServiceImportURLProtocol.capturedPath = nil
        ServiceImportURLProtocol.capturedMethod = nil
        ServiceImportURLProtocol.capturedAuthHeader = nil
        ServiceImportURLProtocol.capturedNativeHeader = nil
        ServiceImportURLProtocol.capturedContentType = nil
        ServiceImportURLProtocol.capturedBody = nil
        ServiceImportURLProtocol.status = 200
        ServiceImportURLProtocol.responseBody = Data(response.utf8)
    }

    /// Decode the captured POST body into a JSON dictionary for key-level asserts.
    private func bodyJSON() throws -> [String: Any] {
        let body = try #require(ServiceImportURLProtocol.capturedBody)
        let obj = try JSONSerialization.jsonObject(with: body)
        return try #require(obj as? [String: Any])
    }

    private static let previewJSON = """
    {
      "ok": true,
      "catalog": [
        {
          "id": "svc_balayage", "name": "Balayage", "categoryName": "Color",
          "minPrice": 150, "defaultDurationMinutes": 180, "allowMobile": false
        },
        {
          "id": "svc_cut", "name": "Haircut & Style", "categoryName": "Hair",
          "minPrice": 60, "defaultDurationMinutes": 60, "allowMobile": true
        }
      ],
      "rows": [
        {
          "index": 0, "sourceName": "Balayage Deluxe", "sourcePrice": 120,
          "sourceDurationMinutes": 150,
          "suggestions": [
            { "serviceId": "svc_balayage", "name": "Balayage", "categoryName": "Color", "score": 92 }
          ],
          "bestServiceId": "svc_balayage"
        },
        {
          "index": 1, "sourceName": "Mystery Ritual", "sourcePrice": null,
          "sourceDurationMinutes": null, "suggestions": [], "bestServiceId": null
        }
      ]
    }
    """

    @Test func previewPostsRowsAndDecodes() async throws {
        reset(response: Self.previewJSON)

        let rows = [
            ServiceMenuInputRow(name: "Balayage Deluxe", price: 120, durationMinutes: 150),
            ServiceMenuInputRow(name: "Mystery Ritual", price: nil, durationMinutes: nil),
        ]

        let preview = try await makeService().previewServiceImport(rows: rows)

        #expect(ServiceImportURLProtocol.capturedPath == "/api/v1/pro/migrate/services/preview")
        #expect(ServiceImportURLProtocol.capturedMethod == "POST")
        #expect(ServiceImportURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(ServiceImportURLProtocol.capturedNativeHeader == "ios")
        #expect(ServiceImportURLProtocol.capturedContentType == "application/json")

        // Body carries the parsed menu rows under `rows`.
        let json = try bodyJSON()
        let sentRows = try #require(json["rows"] as? [[String: Any]])
        #expect(sentRows.count == 2)
        #expect(sentRows[0]["name"] as? String == "Balayage Deluxe")
        #expect((sentRows[0]["price"] as? NSNumber)?.doubleValue == 120)
        // nil price/duration are omitted (server coerces missing → null).
        #expect(sentRows[1]["price"] == nil)
        #expect(sentRows[1]["durationMinutes"] == nil)

        // Decoded catalog + rows + suggestions + confident match.
        #expect(preview.catalog.count == 2)
        let balayage = try #require(preview.catalog.first)
        #expect(balayage.id == "svc_balayage")
        #expect(balayage.minPrice == 150)
        #expect(balayage.defaultDurationMinutes == 180)
        #expect(balayage.allowMobile == false)

        #expect(preview.rows.count == 2)
        let matched = try #require(preview.rows.first)
        #expect(matched.index == 0)
        #expect(matched.sourceName == "Balayage Deluxe")
        #expect(matched.sourcePrice == 120)
        #expect(matched.bestServiceId == "svc_balayage")
        #expect(matched.suggestions.first?.score == 92)

        let unmatched = preview.rows[1]
        #expect(unmatched.bestServiceId == nil)
        #expect(unmatched.sourcePrice == nil)
        #expect(unmatched.suggestions.isEmpty)
    }

    @Test func commitPostsDecisionsAndDecodes() async throws {
        reset(response: """
        {
          "ok": true,
          "rows": [
            { "serviceId": "svc_balayage", "ok": true, "offeringId": "off_1", "ramps": 1 },
            { "serviceId": "svc_cut", "ok": false, "code": "ALREADY_ADDED", "error": "Already on your menu." }
          ],
          "summary": { "attempted": 2, "created": 1, "skipped": 1, "rampsCreated": 1 }
        }
        """)

        let decisions = [
            ServiceImportDecision(
                serviceId: "svc_balayage",
                offersInSalon: true, offersMobile: false,
                salonPrice: 120, salonDurationMinutes: 150,
                mobilePrice: nil, mobileDurationMinutes: nil,
                ramp: ServiceRampConfig(stepMode: .usd, stepValue: 15, cadenceWeeks: 8)
            ),
        ]

        let result = try await makeService().commitServiceImport(decisions: decisions)

        #expect(ServiceImportURLProtocol.capturedPath == "/api/v1/pro/migrate/services/commit")
        #expect(ServiceImportURLProtocol.capturedMethod == "POST")

        // Body carries the decisions incl. the nested ramp object.
        let json = try bodyJSON()
        let sent = try #require(json["decisions"] as? [[String: Any]])
        #expect(sent.count == 1)
        #expect(sent[0]["serviceId"] as? String == "svc_balayage")
        #expect(sent[0]["offersInSalon"] as? Bool == true)
        #expect(sent[0]["offersMobile"] as? Bool == false)
        #expect((sent[0]["salonPrice"] as? NSNumber)?.doubleValue == 120)
        #expect(sent[0]["mobilePrice"] == nil) // nil → omitted
        let ramp = try #require(sent[0]["ramp"] as? [String: Any])
        #expect(ramp["stepMode"] as? String == "USD")
        #expect(ramp["stepValue"] as? Int == 15)
        #expect(ramp["cadenceWeeks"] as? Int == 8)

        // Decoded commit outcome (discriminated on `ok`).
        #expect(result.summary.attempted == 2)
        #expect(result.summary.created == 1)
        #expect(result.summary.skipped == 1)
        #expect(result.summary.rampsCreated == 1)
        let ok = try #require(result.rows.first)
        #expect(ok.ok)
        #expect(ok.offeringId == "off_1")
        #expect(ok.ramps == 1)
        let bad = result.rows[1]
        #expect(bad.ok == false)
        #expect(bad.code == "ALREADY_ADDED")
        #expect(bad.offeringId == nil)
    }

    @Test func previewThrowsServer404WhenFlagOff() async throws {
        reset(response: "{\"ok\":false,\"error\":\"Not found\"}")
        ServiceImportURLProtocol.status = 404

        do {
            _ = try await makeService().previewServiceImport(
                rows: [ServiceMenuInputRow(name: "Cut", price: 40, durationMinutes: 45)]
            )
            Issue.record("expected a 404 to throw")
        } catch let error as APIError {
            guard case .server(404, _, _) = error else {
                Issue.record("expected APIError.server(404), got \(error)")
                return
            }
        }
    }

    // MARK: - Pure CSV helpers

    @Test func parseMenuNumberExtractsFirstNumber() {
        #expect(parseMenuNumber("$45.00") == 45)
        #expect(parseMenuNumber("1,250") == 1250)
        #expect(parseMenuNumber("90 min") == 90)
        #expect(parseMenuNumber("1h 30m") == 1) // first number only
        #expect(parseMenuNumber("free") == nil)
        #expect(parseMenuNumber("") == nil)
        #expect(parseMenuNumber(nil) == nil)
    }

    @Test func parseServiceMenuRowsDetectsColumnsAndDropsBlankNames() {
        let headers = ["Service Name", "Price", "Duration"]
        let rows: [[String: String]] = [
            ["Service Name": "Balayage", "Price": "$120", "Duration": "90 min"],
            ["Service Name": "  ", "Price": "50", "Duration": "30"], // blank name → dropped
        ]
        let parsed = parseServiceMenuRows(headers: headers, rows: rows)
        #expect(parsed.count == 1)
        #expect(parsed[0].name == "Balayage")
        #expect(parsed[0].price == 120)
        #expect(parsed[0].durationMinutes == 90)
    }

    @Test func parseServiceMenuRowsFallsBackToFirstColumnForName() {
        // No service/name/item header → name falls back to the first column;
        // "Cost" matches the price hints.
        let headers = ["Thing", "Cost"]
        let rows: [[String: String]] = [["Thing": "Signature Cut", "Cost": "$40"]]
        let parsed = parseServiceMenuRows(headers: headers, rows: rows)
        #expect(parsed.count == 1)
        #expect(parsed[0].name == "Signature Cut")
        #expect(parsed[0].price == 40)
        #expect(parsed[0].durationMinutes == nil) // no duration column
    }
}
