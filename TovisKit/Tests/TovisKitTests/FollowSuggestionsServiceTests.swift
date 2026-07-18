import Foundation
import Testing
@testable import TovisKit

// GET /api/v1/client/follow-suggestions — the "creators to follow" rail on
// Me › Following.
//
// The happy-path envelope below is a VERBATIM capture from the running route
// (local server, minted CLIENT jwt, 2026-07-18), not a shape invented to match
// the decoder — the two agreeing proves nothing on its own.
//
// Pinned from that drive:
//   • items[] carries { clientId, handle, avatarUrl, likedLookCount } — the
//     suggestions are CLIENTS addressed by handle, not pros by id.
//   • the server owns the exclusions: following a creator empties them out of
//     the very next response, so the client never filters locally.
//   • the follow itself is POST /client/follow/{handle}, a BLIND TOGGLE — a
//     second POST returned {"following":false}, i.e. it unfollowed.

/// Records the outgoing request and serves a canned envelope.
final class FollowSuggestionsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedQuery: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true,\"items\":[]}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedQuery = request.url?.query
        Self.capturedMethod = request.httpMethod

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

@Suite(.serialized) struct FollowSuggestionsServiceTests {
    private func makeService() async -> PublicClientService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FollowSuggestionsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.followsuggestions.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return PublicClientService(api: api)
    }

    private func reset() {
        FollowSuggestionsURLProtocol.capturedPath = nil
        FollowSuggestionsURLProtocol.capturedQuery = nil
        FollowSuggestionsURLProtocol.capturedMethod = nil
        FollowSuggestionsURLProtocol.status = 200
        FollowSuggestionsURLProtocol.responseBody = Data("{\"ok\":true,\"items\":[]}".utf8)
    }

    // MARK: - The verbatim capture

    @Test func decodesTheLiveEnvelope() async throws {
        reset()
        // VERBATIM from the running route.
        FollowSuggestionsURLProtocol.responseBody = Data("""
        {"ok":true,"items":[{"clientId":"cmrbry47p000dpo0dcsf18d0l","handle":"ava","avatarUrl":"https://picsum.photos/seed/ava/200","likedLookCount":1}]}
        """.utf8)

        let items = try await makeService().followSuggestions()

        #expect(FollowSuggestionsURLProtocol.capturedPath == "/api/v1/client/follow-suggestions")
        #expect(FollowSuggestionsURLProtocol.capturedMethod == "GET")
        #expect(FollowSuggestionsURLProtocol.capturedQuery == nil)  // no limit → no query

        #expect(items.count == 1)
        let first = try #require(items.first)
        #expect(first.clientId == "cmrbry47p000dpo0dcsf18d0l")
        #expect(first.handle == "ava")
        #expect(first.avatarUrl == "https://picsum.photos/seed/ava/200")
        #expect(first.likedLookCount == 1)
        #expect(first.id == first.clientId)  // Identifiable keys on clientId
    }

    /// Also verbatim: what the route returns once the viewer follows the only
    /// suggestion. The rail hides itself rather than filtering anything locally.
    @Test func decodesTheEmptiedEnvelopeAfterFollowing() async throws {
        reset()
        FollowSuggestionsURLProtocol.responseBody = Data("""
        {"ok":true,"items":[]}
        """.utf8)

        let items = try await makeService().followSuggestions()

        #expect(items.isEmpty)
    }

    @Test func sendsLimitWhenAsked() async throws {
        reset()

        _ = try await makeService().followSuggestions(limit: 5)

        #expect(FollowSuggestionsURLProtocol.capturedQuery == "limit=5")
    }

    // MARK: - Defensive decoding

    /// The rail sits on the Following tab; one malformed row must not blank the
    /// tab. Rows without the two fields the UI cannot work without are dropped,
    /// and the good ones still render.
    @Test func dropsRowsMissingIdentityAndKeepsTheRest() async throws {
        reset()
        FollowSuggestionsURLProtocol.responseBody = Data("""
        {"ok":true,"items":[
          {"clientId":"c_1","avatarUrl":null,"likedLookCount":3},
          {"handle":"noid","avatarUrl":null,"likedLookCount":2},
          {"clientId":"c_2","handle":"  ","avatarUrl":null,"likedLookCount":1},
          {"clientId":"c_3","handle":"keeper","avatarUrl":null,"likedLookCount":4}
        ]}
        """.utf8)

        let items = try await makeService().followSuggestions()

        #expect(items.count == 1)
        #expect(items.first?.handle == "keeper")
    }

    @Test func toleratesMissingLikedLookCount() async throws {
        reset()
        FollowSuggestionsURLProtocol.responseBody = Data("""
        {"ok":true,"items":[{"clientId":"c_1","handle":"ava","avatarUrl":null}]}
        """.utf8)

        let items = try await makeService().followSuggestions()

        #expect(items.first?.likedLookCount == 0)
        #expect(items.first?.avatarUrl == nil)
    }

    @Test func toleratesMissingItemsKey() async throws {
        reset()
        FollowSuggestionsURLProtocol.responseBody = Data("{\"ok\":true}".utf8)

        let items = try await makeService().followSuggestions()

        #expect(items.isEmpty)
    }

    /// An unknown field arriving later must not throw — the whole reason the row
    /// decodes leniently rather than exactly.
    @Test func ignoresUnknownFields() async throws {
        reset()
        FollowSuggestionsURLProtocol.responseBody = Data("""
        {"ok":true,"items":[{"clientId":"c_1","handle":"ava","avatarUrl":null,"likedLookCount":2,"mutualFollowers":9}]}
        """.utf8)

        let items = try await makeService().followSuggestions()

        #expect(items.count == 1)
        #expect(items.first?.likedLookCount == 2)
    }
}
