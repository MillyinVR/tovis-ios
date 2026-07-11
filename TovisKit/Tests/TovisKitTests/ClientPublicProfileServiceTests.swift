import Foundation
import Testing
@testable import TovisKit

// Proves the client public-profile surface hits the right routes and encodes the
// PATCH body the way the web card does:
//   • profile()       → GET   /client/profile → { profile }   (handle/bio nullable)
//   • updateProfile() → PATCH /client/profile → { ok, profile }
// Unlike the /client/settings PATCH (explicit-null clears), this route clears
// handle/publicBio via an EMPTY STRING — so all three keys are always present as
// plain values (handle: String, isPublicProfile: Bool, publicBio: String).
// Also covers the HandleRules.sanitizeInput port of lib/handles.sanitizeHandleInput.

/// Records the outgoing request and serves a canned envelope.
final class ClientPublicProfileURLProtocol: URLProtocol {
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
        Self.capturedBody = request.httpBody ?? request.clientPublicProfileBodyStreamData()

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
    func clientPublicProfileBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ClientPublicProfileServiceTests {
    private func makeService() async -> ClientPublicProfileService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientPublicProfileURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.clientpublicprofile.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ClientPublicProfileService(api: api)
    }

    private func reset() {
        ClientPublicProfileURLProtocol.capturedPath = nil
        ClientPublicProfileURLProtocol.capturedMethod = nil
        ClientPublicProfileURLProtocol.capturedAuthHeader = nil
        ClientPublicProfileURLProtocol.capturedContentType = nil
        ClientPublicProfileURLProtocol.capturedBody = nil
        ClientPublicProfileURLProtocol.status = 200
        ClientPublicProfileURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    private func decodeBody(_ data: Data?) throws -> [String: Any] {
        let body = try #require(data)
        let json = try JSONSerialization.jsonObject(with: body)
        return try #require(json as? [String: Any])
    }

    // MARK: - profile()

    @Test func profileGetsAndUnwrapsEnvelope() async throws {
        reset()
        ClientPublicProfileURLProtocol.responseBody = Data("""
        {"ok":true,"profile":{"id":"cp_1","handle":"amara","isPublicProfile":true,"publicBio":"Balayage & lived-in color."}}
        """.utf8)

        let profile = try await makeService().profile()

        #expect(ClientPublicProfileURLProtocol.capturedPath == "/api/v1/client/profile")
        #expect(ClientPublicProfileURLProtocol.capturedMethod == "GET")
        #expect(ClientPublicProfileURLProtocol.capturedAuthHeader == "Bearer session.token.value")

        #expect(profile.id == "cp_1")
        #expect(profile.handle == "amara")
        #expect(profile.isPublicProfile == true)
        #expect(profile.publicBio == "Balayage & lived-in color.")
    }

    @Test func profileDecodesUnsetNullableFields() async throws {
        reset()
        // A brand-new client: no handle claimed, private, no bio.
        ClientPublicProfileURLProtocol.responseBody = Data("""
        {"ok":true,"profile":{"id":"cp_1","handle":null,"isPublicProfile":false,"publicBio":null}}
        """.utf8)

        let profile = try await makeService().profile()

        #expect(profile.handle == nil)
        #expect(profile.isPublicProfile == false)
        #expect(profile.publicBio == nil)
    }

    // MARK: - updateProfile()

    @Test func updateProfilePatchesWithAllThreeKeys() async throws {
        reset()
        ClientPublicProfileURLProtocol.responseBody = Data("""
        {"ok":true,"profile":{"id":"cp_1","handle":"amara","isPublicProfile":true,"publicBio":"Curl specialist."}}
        """.utf8)

        let updated = try await makeService().updateProfile(
            handle: "amara",
            isPublicProfile: true,
            publicBio: "Curl specialist."
        )

        #expect(ClientPublicProfileURLProtocol.capturedPath == "/api/v1/client/profile")
        #expect(ClientPublicProfileURLProtocol.capturedMethod == "PATCH")
        #expect(ClientPublicProfileURLProtocol.capturedContentType == "application/json")

        let sent = try decodeBody(ClientPublicProfileURLProtocol.capturedBody)
        #expect(sent["handle"] as? String == "amara")
        #expect(sent["isPublicProfile"] as? Bool == true)
        #expect(sent["publicBio"] as? String == "Curl specialist.")

        #expect(updated.handle == "amara")
        #expect(updated.isPublicProfile == true)
    }

    @Test func updateProfileClearsViaEmptyStringsNotNull() async throws {
        reset()
        ClientPublicProfileURLProtocol.responseBody = Data("""
        {"ok":true,"profile":{"id":"cp_1","handle":null,"isPublicProfile":false,"publicBio":null}}
        """.utf8)

        _ = try await makeService().updateProfile(
            handle: "",
            isPublicProfile: false,
            publicBio: ""
        )

        // This route clears via empty strings (the server trims + treats "" as clear),
        // NOT explicit null — so the keys must be present as empty STRINGS.
        let sent = try decodeBody(ClientPublicProfileURLProtocol.capturedBody)
        #expect(sent["handle"] as? String == "")
        #expect(sent["publicBio"] as? String == "")
        #expect(sent["isPublicProfile"] as? Bool == false)
        #expect(sent["handle"] is NSNull == false)
        #expect(sent["publicBio"] is NSNull == false)
    }

    // MARK: - HandleRules.sanitizeInput (port of lib/handles.sanitizeHandleInput)

    @Test func sanitizeInputLowercasesAndStrips() {
        #expect(HandleRules.sanitizeInput("Amara Rose!") == "amararose")
        #expect(HandleRules.sanitizeInput("  Glow_Up  ") == "glowup")
        #expect(HandleRules.sanitizeInput("café☕studio") == "cafstudio")
    }

    @Test func sanitizeInputTrimsHyphensAndCaps() {
        #expect(HandleRules.sanitizeInput("--hi--") == "hi")
        #expect(HandleRules.sanitizeInput("a-b-c") == "a-b-c")
        // Caps at HandleRules.max (24).
        let long = String(repeating: "a", count: 40)
        #expect(HandleRules.sanitizeInput(long).count == HandleRules.max)
    }
}
