import Foundation
import Testing
@testable import TovisKit

// Proves the handle-addressed public creator surface hits the right routes:
//   • profile(handle:)      → GET  /u/{handle}            → { profile } (nil on 404)
//   • toggleFollow(handle:) → POST /client/follow/{handle} → { following, followerCount }
// The public-profile GET is public-read; a 404 means "no such public profile"
// (surfaced as nil), any other non-2xx throws. The follow POST is a toggle (empty
// `{}` body) and returns the authoritative state.

/// Records the outgoing request and serves a canned envelope.
final class PublicClientURLProtocol: URLProtocol {
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
        Self.capturedBody = request.httpBody ?? request.publicClientBodyStreamData()

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
    func publicClientBodyStreamData() -> Data? {
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

@Suite(.serialized) struct PublicClientServiceTests {
    private func makeService() async -> PublicClientService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublicClientURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.publicclient.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return PublicClientService(api: api)
    }

    private func reset() {
        PublicClientURLProtocol.capturedPath = nil
        PublicClientURLProtocol.capturedMethod = nil
        PublicClientURLProtocol.capturedAuthHeader = nil
        PublicClientURLProtocol.capturedNativeHeader = nil
        PublicClientURLProtocol.capturedContentType = nil
        PublicClientURLProtocol.capturedBody = nil
        PublicClientURLProtocol.status = 200
        PublicClientURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    // MARK: - profile(handle:)

    @Test func profileGetsAndUnwrapsEnvelope() async throws {
        reset()
        PublicClientURLProtocol.responseBody = Data("""
        {"ok":true,"profile":{"handle":"amara","displayName":"@amara","avatarUrl":"https://cdn/a.jpg","bio":"hi there","counts":{"followers":12,"following":3,"looks":4},"looks":[{"id":"lk_1","name":"Balayage","imageUrl":"https://cdn/l.jpg","saveCount":9,"href":"/looks/lk_1"}],"viewer":{"isOwn":false,"following":true}}}
        """.utf8)

        let profile = try await makeService().profile(handle: "amara")

        #expect(PublicClientURLProtocol.capturedPath == "/api/v1/u/amara")
        #expect(PublicClientURLProtocol.capturedMethod == "GET")
        #expect(PublicClientURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(PublicClientURLProtocol.capturedNativeHeader == "ios")

        #expect(profile?.handle == "amara")
        #expect(profile?.displayName == "@amara")
        #expect(profile?.bio == "hi there")
        #expect(profile?.counts.followers == 12)
        #expect(profile?.counts.following == 3)
        #expect(profile?.counts.looks == 4)
        #expect(profile?.looks.first?.saveCount == 9)
        #expect(profile?.looks.first?.name == "Balayage")
        #expect(profile?.viewer.isOwn == false)
        #expect(profile?.viewer.following == true)
    }

    @Test func profileReturnsNilOn404() async throws {
        reset()
        PublicClientURLProtocol.status = 404
        PublicClientURLProtocol.responseBody = Data("{\"ok\":false,\"error\":\"Profile not found.\"}".utf8)

        let profile = try await makeService().profile(handle: "ghost")

        #expect(PublicClientURLProtocol.capturedPath == "/api/v1/u/ghost")
        #expect(profile == nil)
    }

    @Test func profileThrowsOnOtherServerError() async throws {
        reset()
        PublicClientURLProtocol.status = 500
        PublicClientURLProtocol.responseBody = Data("{\"ok\":false,\"error\":\"Failed to load profile.\"}".utf8)

        do {
            _ = try await makeService().profile(handle: "amara")
            Issue.record("expected profile(handle:) to throw on a 500")
        } catch let error as APIError {
            guard case let .server(status, _, _) = error else {
                Issue.record("expected APIError.server, got \(error)")
                return
            }
            #expect(status == 500)
        }
    }

    // MARK: - toggleFollow(handle:)

    @Test func toggleFollowPostsEmptyBodyAndDecodesState() async throws {
        reset()
        PublicClientURLProtocol.responseBody = Data(
            "{\"ok\":true,\"handle\":\"amara\",\"following\":true,\"followerCount\":13}".utf8
        )

        let state = try await makeService().toggleFollow(handle: "amara")

        #expect(PublicClientURLProtocol.capturedPath == "/api/v1/client/follow/amara")
        #expect(PublicClientURLProtocol.capturedMethod == "POST")
        #expect(PublicClientURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(PublicClientURLProtocol.capturedNativeHeader == "ios")
        #expect(PublicClientURLProtocol.capturedContentType == "application/json")

        let body = try #require(PublicClientURLProtocol.capturedBody)
        #expect(String(decoding: body, as: UTF8.self) == "{}")

        #expect(state.following == true)
        #expect(state.followerCount == 13)
    }
}
