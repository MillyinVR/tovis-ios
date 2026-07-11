import Foundation
import Testing
@testable import TovisKit

// Proves the client account-settings surface hits the right routes and encodes the
// PATCH body the way the web form does:
//   • profile()       → GET   /client/settings → { profile }  (incl. phone + dateOfBirth)
//   • updateProfile() → PATCH /client/settings → { profile }
// The PATCH always sends all five keys; the three nullable ones are encoded as an
// explicit JSON `null` when cleared (an absent key would read as "no change").

/// Records the outgoing request and serves a canned envelope.
final class ClientSettingsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedAuthHeader: String?
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
        Self.capturedContentType = request.value(forHTTPHeaderField: "Content-Type")
        Self.capturedBody = request.httpBody ?? request.clientSettingsBodyStreamData()

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
    func clientSettingsBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ClientSettingsServiceTests {
    private func makeService() async -> ClientSettingsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientSettingsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.clientsettings.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ClientSettingsService(api: api)
    }

    private func reset() {
        ClientSettingsURLProtocol.capturedPath = nil
        ClientSettingsURLProtocol.capturedMethod = nil
        ClientSettingsURLProtocol.capturedAuthHeader = nil
        ClientSettingsURLProtocol.capturedContentType = nil
        ClientSettingsURLProtocol.capturedBody = nil
        ClientSettingsURLProtocol.status = 200
        ClientSettingsURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    private func decodeBody(_ data: Data?) throws -> [String: Any] {
        let body = try #require(data)
        let json = try JSONSerialization.jsonObject(with: body)
        return try #require(json as? [String: Any])
    }

    // MARK: - profile()

    @Test func profileGetsAndUnwrapsEnvelope() async throws {
        reset()
        ClientSettingsURLProtocol.responseBody = Data("""
        {"ok":true,"profile":{"id":"cp_1","email":"amara@example.com","firstName":"Amara","lastName":"Okoye","phone":"+1 (415) 555-0100","avatarUrl":"https://cdn/a.jpg","dateOfBirth":"1994-03-07"},"addresses":[]}
        """.utf8)

        let profile = try await makeService().profile()

        #expect(ClientSettingsURLProtocol.capturedPath == "/api/v1/client/settings")
        #expect(ClientSettingsURLProtocol.capturedMethod == "GET")
        #expect(ClientSettingsURLProtocol.capturedAuthHeader == "Bearer session.token.value")

        #expect(profile.id == "cp_1")
        #expect(profile.email == "amara@example.com")
        #expect(profile.firstName == "Amara")
        #expect(profile.lastName == "Okoye")
        #expect(profile.phone == "+1 (415) 555-0100")
        #expect(profile.avatarUrl == "https://cdn/a.jpg")
        #expect(profile.dateOfBirth == "1994-03-07")
    }

    @Test func profileDecodesClearedNullableFields() async throws {
        reset()
        ClientSettingsURLProtocol.responseBody = Data("""
        {"ok":true,"profile":{"id":"cp_1","email":"amara@example.com","firstName":"Amara","lastName":"","phone":null,"avatarUrl":null,"dateOfBirth":null}}
        """.utf8)

        let profile = try await makeService().profile()

        #expect(profile.lastName == "")
        #expect(profile.phone == nil)
        #expect(profile.avatarUrl == nil)
        #expect(profile.dateOfBirth == nil)
    }

    // MARK: - updateProfile()

    @Test func updateProfilePatchesWithAllFields() async throws {
        reset()
        ClientSettingsURLProtocol.responseBody = Data("""
        {"ok":true,"profile":{"id":"cp_1","email":"amara@example.com","firstName":"Amara","lastName":"Okoye","phone":"+14155550100","avatarUrl":"https://cdn/b.jpg","dateOfBirth":"1994-03-07"}}
        """.utf8)

        let updated = try await makeService().updateProfile(
            firstName: "Amara",
            lastName: "Okoye",
            phone: "+14155550100",
            avatarUrl: "https://cdn/b.jpg",
            dateOfBirth: "1994-03-07"
        )

        #expect(ClientSettingsURLProtocol.capturedPath == "/api/v1/client/settings")
        #expect(ClientSettingsURLProtocol.capturedMethod == "PATCH")
        #expect(ClientSettingsURLProtocol.capturedContentType == "application/json")

        let sent = try decodeBody(ClientSettingsURLProtocol.capturedBody)
        #expect(sent["firstName"] as? String == "Amara")
        #expect(sent["lastName"] as? String == "Okoye")
        #expect(sent["phone"] as? String == "+14155550100")
        #expect(sent["avatarUrl"] as? String == "https://cdn/b.jpg")
        #expect(sent["dateOfBirth"] as? String == "1994-03-07")

        #expect(updated.phone == "+14155550100")
        #expect(updated.avatarUrl == "https://cdn/b.jpg")
    }

    @Test func updateProfileSendsExplicitNullsToClear() async throws {
        reset()
        ClientSettingsURLProtocol.responseBody = Data("""
        {"ok":true,"profile":{"id":"cp_1","email":"amara@example.com","firstName":"Amara","lastName":"Okoye","phone":null,"avatarUrl":null,"dateOfBirth":null}}
        """.utf8)

        _ = try await makeService().updateProfile(
            firstName: "Amara",
            lastName: "Okoye",
            phone: nil,
            avatarUrl: nil,
            dateOfBirth: nil
        )

        // The three nullable keys must be PRESENT and explicitly null (not omitted),
        // so the backend clears them rather than treating them as "no change".
        let sent = try decodeBody(ClientSettingsURLProtocol.capturedBody)
        #expect(sent.keys.contains("phone"))
        #expect(sent.keys.contains("avatarUrl"))
        #expect(sent.keys.contains("dateOfBirth"))
        #expect(sent["phone"] is NSNull)
        #expect(sent["avatarUrl"] is NSNull)
        #expect(sent["dateOfBirth"] is NSNull)
        #expect(sent["firstName"] as? String == "Amara")
    }
}
