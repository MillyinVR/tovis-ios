import Foundation
import Testing
@testable import TovisKit

// Proves the migration wizard's clients-import methods hit the right routes with
// the right verbs + bodies and decode the preview/commit envelopes (existing web
// routes, POST-only, no DTO — an iOS-only port):
//   • previewClientImport → POST /pro/migrate/clients/preview { rows, mapping }
//                           (no excludeIndices) → { rows, summary }
//   • commitClientImport  → POST /pro/migrate/clients/commit  { rows, mapping,
//                           excludeIndices } → { rows, summary }
//   • 404 while ENABLE_PRO_MIGRATION is off → APIError.server(404) (build-dark)
// Plus the pure mapping helpers (guess + required-field gate).

/// Records the outgoing request (incl. POST body) and serves a canned envelope.
final class ClientImportURLProtocol: URLProtocol {
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
        Self.capturedBody = request.httpBody ?? request.clientImportBodyStreamData()

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
    func clientImportBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ProMigrationClientImportTests {
    private func makeService() async -> ProMigrationService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientImportURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.clientimport.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProMigrationService(api: api)
    }

    private func reset(response: String) {
        ClientImportURLProtocol.capturedPath = nil
        ClientImportURLProtocol.capturedMethod = nil
        ClientImportURLProtocol.capturedAuthHeader = nil
        ClientImportURLProtocol.capturedNativeHeader = nil
        ClientImportURLProtocol.capturedContentType = nil
        ClientImportURLProtocol.capturedBody = nil
        ClientImportURLProtocol.status = 200
        ClientImportURLProtocol.responseBody = Data(response.utf8)
    }

    /// Decode the captured POST body into a JSON dictionary for key-level asserts.
    private func bodyJSON() throws -> [String: Any] {
        let body = try #require(ClientImportURLProtocol.capturedBody)
        let obj = try JSONSerialization.jsonObject(with: body)
        return try #require(obj as? [String: Any])
    }

    private static let previewJSON = """
    {
      "ok": true,
      "rows": [
        {
          "index": 0, "firstName": "Jane", "lastName": "Doe",
          "email": "jane@x.com", "phone": null,
          "match": "NEW", "issues": [], "importable": true
        },
        {
          "index": 1, "firstName": "Sam", "lastName": "Lee",
          "email": null, "phone": "+15551234567",
          "match": "EXISTING", "issues": [], "importable": true
        },
        {
          "index": 2, "firstName": "NoContact", "lastName": "",
          "email": null, "phone": null,
          "match": "MISSING_INFO", "issues": ["MISSING_NAME", "MISSING_CONTACT"],
          "importable": false
        }
      ],
      "summary": { "total": 3, "importable": 2, "existing": 1, "new": 1, "needsAttention": 1 }
    }
    """

    @Test func previewPostsRowsAndMappingAndDecodes() async throws {
        reset(response: Self.previewJSON)

        let rows = [
            ["First": "Jane", "Last": "Doe", "Email": "jane@x.com"],
            ["First": "Sam", "Last": "Lee", "Phone": "555-123-4567"],
        ]
        let mapping = ClientImportMapping(firstName: "First", lastName: "Last", email: "Email", phone: "Phone")

        let preview = try await makeService().previewClientImport(rows: rows, mapping: mapping)

        #expect(ClientImportURLProtocol.capturedPath == "/api/v1/pro/migrate/clients/preview")
        #expect(ClientImportURLProtocol.capturedMethod == "POST")
        #expect(ClientImportURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(ClientImportURLProtocol.capturedNativeHeader == "ios")
        #expect(ClientImportURLProtocol.capturedContentType == "application/json")

        // Body carries rows + mapping, and NO excludeIndices for preview.
        let json = try bodyJSON()
        let sentRows = try #require(json["rows"] as? [[String: String]])
        #expect(sentRows.count == 2)
        let sentMapping = try #require(json["mapping"] as? [String: String])
        #expect(sentMapping["firstName"] == "First")
        #expect(sentMapping["lastName"] == "Last")
        #expect(sentMapping["email"] == "Email")
        #expect(sentMapping["phone"] == "Phone")
        #expect(json["excludeIndices"] == nil)

        // Decoded preview + derived helpers.
        #expect(preview.rows.count == 3)
        #expect(preview.summary.total == 3)
        #expect(preview.summary.importable == 2)
        #expect(preview.summary.existing == 1)
        #expect(preview.summary.newCount == 1)
        #expect(preview.summary.needsAttention == 1)

        let jane = try #require(preview.rows.first)
        #expect(jane.kind == .new)
        #expect(jane.displayName == "Jane Doe")
        #expect(jane.contactLine == "jane@x.com")
        #expect(jane.importable)

        let sam = preview.rows[1]
        #expect(sam.kind == .existing)
        #expect(sam.contactLine == "+15551234567") // no email → phone

        let missing = preview.rows[2]
        #expect(missing.kind == .missingInfo)
        #expect(missing.importable == false)
        #expect(missing.contactLine == nil)
        #expect(missing.issues.contains("MISSING_CONTACT"))
    }

    @Test func previewOmitsUnmappedOptionalFields() async throws {
        reset(response: Self.previewJSON)

        let mapping = ClientImportMapping(firstName: "First", lastName: "Last") // no email/phone
        _ = try await makeService().previewClientImport(rows: [["First": "A", "Last": "B"]], mapping: mapping)

        let sentMapping = try #require(try bodyJSON()["mapping"] as? [String: String])
        #expect(sentMapping["firstName"] == "First")
        #expect(sentMapping["lastName"] == "Last")
        // encodeIfPresent drops the unmapped optionals (web deletes the keys too).
        #expect(sentMapping["email"] == nil)
        #expect(sentMapping["phone"] == nil)
    }

    @Test func commitPostsExcludeIndicesAndDecodes() async throws {
        reset(response: """
        {
          "ok": true,
          "rows": [
            { "index": 0, "ok": true, "clientId": "cli_1" },
            { "index": 1, "ok": false, "error": "That email or phone is already used by a non-client account.", "code": "CONTACT_IN_USE_BY_NON_CLIENT" }
          ],
          "summary": { "attempted": 2, "imported": 1, "failed": 1, "skipped": 1 }
        }
        """)

        let mapping = ClientImportMapping(firstName: "First", lastName: "Last", email: "Email")
        let result = try await makeService().commitClientImport(
            rows: [["First": "Jane", "Last": "Doe", "Email": "jane@x.com"]],
            mapping: mapping,
            excludeIndices: [2, 5]
        )

        #expect(ClientImportURLProtocol.capturedPath == "/api/v1/pro/migrate/clients/commit")
        #expect(ClientImportURLProtocol.capturedMethod == "POST")

        let json = try bodyJSON()
        let excludes = try #require(json["excludeIndices"] as? [Int])
        #expect(excludes == [2, 5])
        #expect(json["mapping"] as? [String: String] != nil)

        // Decoded commit outcome (discriminated on `ok`).
        #expect(result.summary.attempted == 2)
        #expect(result.summary.imported == 1)
        #expect(result.summary.failed == 1)
        #expect(result.summary.skipped == 1)
        let ok = try #require(result.rows.first)
        #expect(ok.ok)
        #expect(ok.clientId == "cli_1")
        let bad = result.rows[1]
        #expect(bad.ok == false)
        #expect(bad.code == "CONTACT_IN_USE_BY_NON_CLIENT")
        #expect(bad.clientId == nil)
    }

    @Test func previewThrowsServer404WhenFlagOff() async throws {
        reset(response: "{\"ok\":false,\"error\":\"Not found\"}")
        ClientImportURLProtocol.status = 404

        do {
            _ = try await makeService().previewClientImport(
                rows: [["First": "A", "Last": "B"]],
                mapping: ClientImportMapping(firstName: "First", lastName: "Last")
            )
            Issue.record("expected a 404 to throw")
        } catch let error as APIError {
            guard case .server(404, _, _) = error else {
                Issue.record("expected APIError.server(404), got \(error)")
                return
            }
        }
    }

    // MARK: - Pure mapping helpers

    @Test func guessMappingMatchesHeadersBySubstring() {
        let guess = guessClientImportMapping(headers: ["First Name", "Surname", "E-Mail Address", "Mobile", "Notes"])
        #expect(guess[.firstName] == "First Name")
        #expect(guess[.lastName] == "Surname")
        #expect(guess[.email] == "E-Mail Address")
        #expect(guess[.phone] == "Mobile")
    }

    @Test func mappingRequiresBothNameFields() {
        #expect(ClientImportMapping(selection: [.firstName: "First"]) == nil)
        #expect(ClientImportMapping(selection: [.firstName: "First", .lastName: ""]) == nil)
        let ok = ClientImportMapping(selection: [.firstName: "First", .lastName: "Last", .email: "Email"])
        #expect(ok?.firstName == "First")
        #expect(ok?.lastName == "Last")
        #expect(ok?.email == "Email")
        #expect(ok?.phone == nil)
    }
}
