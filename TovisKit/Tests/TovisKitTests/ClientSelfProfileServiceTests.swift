import Foundation
import Testing
@testable import TovisKit

// Proves the client personalization self-profile surface hits the right routes and
// encodes the PATCH body the way the web card (ClientSelfProfileSettings) does:
//   • profile() → GET   /client/self-profile → { selfProfile } (null when unset)
//   • update()  → PATCH /client/self-profile → { ok, selfProfile }
// The route reads/writes snake_case keys. Every field key is sent EVERY time — the
// chosen value, or an explicit JSON null to clear an unselected field — plus the full
// interests array (an empty array clears them all). An absent field key would mean "no
// change" server-side, so unselected fields must serialize as null, never be omitted.

/// Records the outgoing request and serves a canned envelope.
final class ClientSelfProfileURLProtocol: URLProtocol {
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
        Self.capturedBody = request.httpBody ?? request.clientSelfProfileBodyStreamData()

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
    func clientSelfProfileBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ClientSelfProfileServiceTests {
    private func makeService() async -> ClientSelfProfileService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientSelfProfileURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.selfprofile.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ClientSelfProfileService(api: api)
    }

    private func reset() {
        ClientSelfProfileURLProtocol.capturedPath = nil
        ClientSelfProfileURLProtocol.capturedMethod = nil
        ClientSelfProfileURLProtocol.capturedAuthHeader = nil
        ClientSelfProfileURLProtocol.capturedContentType = nil
        ClientSelfProfileURLProtocol.capturedBody = nil
        ClientSelfProfileURLProtocol.status = 200
        ClientSelfProfileURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    private func decodeBody(_ data: Data?) throws -> [String: Any] {
        let body = try #require(data)
        let json = try JSONSerialization.jsonObject(with: body)
        return try #require(json as? [String: Any])
    }

    // MARK: - profile()

    @Test func profileGetsAndUnwrapsEnvelope() async throws {
        reset()
        ClientSelfProfileURLProtocol.responseBody = Data("""
        {"ok":true,"updatedAt":"2026-07-10T12:00:00.000Z","selfProfile":{"hair_type":"curly","hair_length":"long","hair_color":"brunette","skin_type":"combination","skin_concern":"acne","interests":["hair","nails"]}}
        """.utf8)

        let profile = try #require(try await makeService().profile())

        #expect(ClientSelfProfileURLProtocol.capturedPath == "/api/v1/client/self-profile")
        #expect(ClientSelfProfileURLProtocol.capturedMethod == "GET")
        #expect(ClientSelfProfileURLProtocol.capturedAuthHeader == "Bearer session.token.value")

        #expect(profile.hairType == "curly")
        #expect(profile.hairLength == "long")
        #expect(profile.hairColor == "brunette")
        #expect(profile.skinType == "combination")
        #expect(profile.skinConcern == "acne")
        #expect(profile.interests == ["hair", "nails"])
        // The convenience accessor mirrors the stored value for each field key.
        #expect(profile.value(for: .hairType) == "curly")
        #expect(profile.value(for: .skinConcern) == "acne")
    }

    @Test func profileDecodesNullSelfProfileAsNil() async throws {
        reset()
        // A brand-new client who has never touched personalization.
        ClientSelfProfileURLProtocol.responseBody = Data("""
        {"ok":true,"updatedAt":null,"selfProfile":null}
        """.utf8)

        let profile = try await makeService().profile()
        #expect(profile == nil)
    }

    @Test func profileDefaultsMissingFieldsAndInterests() async throws {
        reset()
        // Only hair_type set; no interests key at all.
        ClientSelfProfileURLProtocol.responseBody = Data("""
        {"ok":true,"selfProfile":{"hair_type":"wavy"}}
        """.utf8)

        let profile = try #require(try await makeService().profile())
        #expect(profile.hairType == "wavy")
        #expect(profile.hairLength == nil)
        #expect(profile.skinConcern == nil)
        #expect(profile.interests == [])
    }

    // MARK: - update()

    @Test func updateSendsEverySelectedFieldAndInterests() async throws {
        reset()
        ClientSelfProfileURLProtocol.responseBody = Data("""
        {"ok":true,"selfProfile":{"hair_type":"coily","skin_type":"dry","interests":["skincare"]}}
        """.utf8)

        let updated = try #require(try await makeService().update(
            fields: [.hairType: "coily", .skinType: "dry"],
            interests: ["skincare"]
        ))

        #expect(ClientSelfProfileURLProtocol.capturedPath == "/api/v1/client/self-profile")
        #expect(ClientSelfProfileURLProtocol.capturedMethod == "PATCH")
        #expect(ClientSelfProfileURLProtocol.capturedContentType == "application/json")

        let sent = try decodeBody(ClientSelfProfileURLProtocol.capturedBody)
        // Selected fields carry their chosen value.
        #expect(sent["hair_type"] as? String == "coily")
        #expect(sent["skin_type"] as? String == "dry")
        // Interests are the full array.
        #expect(sent["interests"] as? [String] == ["skincare"])

        #expect(updated.hairType == "coily")
        #expect(updated.skinType == "dry")
        #expect(updated.interests == ["skincare"])
    }

    @Test func updateClearsUnselectedFieldsViaExplicitNull() async throws {
        reset()
        ClientSelfProfileURLProtocol.responseBody = Data("""
        {"ok":true,"selfProfile":{"hair_type":"straight"}}
        """.utf8)

        // Only hair_type chosen — every other field key must still be present as JSON null,
        // never omitted (an absent key means "no change" server-side).
        _ = try await makeService().update(fields: [.hairType: "straight"], interests: [])

        let sent = try decodeBody(ClientSelfProfileURLProtocol.capturedBody)
        #expect(sent["hair_type"] as? String == "straight")

        for key in ["hair_length", "hair_color", "skin_type", "skin_concern"] {
            #expect(sent.keys.contains(key), "expected \(key) key present")
            #expect(sent[key] is NSNull, "expected \(key) to be explicit null")
        }
        // All five field keys are always on the wire.
        #expect(SelfProfileFieldKey.allCases.allSatisfy { sent.keys.contains($0.rawValue) })
    }

    @Test func updateSendsEmptyInterestsArrayToClearThem() async throws {
        reset()
        ClientSelfProfileURLProtocol.responseBody = Data("""
        {"ok":true,"selfProfile":null}
        """.utf8)

        // Nothing selected: all field keys null + interests as an empty array (which
        // clears every interest), and the server can normalize the whole thing to null.
        let updated = try await makeService().update(fields: [:], interests: [])

        let sent = try decodeBody(ClientSelfProfileURLProtocol.capturedBody)
        let interests = try #require(sent["interests"] as? [String])
        #expect(interests.isEmpty)
        #expect(sent["interests"] is NSNull == false)
        for key in SelfProfileFieldKey.allCases {
            #expect(sent[key.rawValue] is NSNull, "expected \(key.rawValue) to be explicit null")
        }
        // A fully-cleared profile normalizes to null server-side → nil for the caller.
        #expect(updated == nil)
    }

    // MARK: - Catalog (port of lib/personalization/selfProfile.ts)

    @Test func catalogMatchesTheWebLib() {
        // Five single-choice questions, in the web order.
        #expect(SelfProfileCatalog.questions.map(\.key) == [
            .hairType, .hairLength, .hairColor, .skinType, .skinConcern,
        ])
        // hair_color option values match the web lib 1:1.
        let hairColor = SelfProfileCatalog.questions.first { $0.key == .hairColor }
        #expect(hairColor?.options.map(\.value) == ["blonde", "brunette", "black", "red", "gray", "other"])
        // Interest values match the web lib 1:1.
        #expect(SelfProfileCatalog.interestOptions.map(\.value) == [
            "hair", "hair-color", "makeup", "nails", "skincare", "brows",
        ])
    }
}
