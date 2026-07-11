import Foundation
import Testing
@testable import TovisKit

// Proves the handle+slug-addressed public board surface hits the right route:
//   • board(handle:slug:) → GET /u/{handle}/boards/{slug} → { board } (nil on 404)
// The GET is public-read but native still sends its bearer; a 404 means "no such
// shared board" (surfaced as nil), any other non-2xx throws.

/// Records the outgoing request and serves a canned envelope.
final class PublicBoardURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedAuthHeader: String?
    nonisolated(unsafe) static var capturedNativeHeader: String?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedAuthHeader = request.value(forHTTPHeaderField: "Authorization")
        Self.capturedNativeHeader = request.value(forHTTPHeaderField: "x-tovis-native")

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

@Suite(.serialized) struct PublicBoardServiceTests {
    private func makeService() async -> PublicBoardService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PublicBoardURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.publicboard.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return PublicBoardService(api: api)
    }

    private func reset() {
        PublicBoardURLProtocol.capturedPath = nil
        PublicBoardURLProtocol.capturedMethod = nil
        PublicBoardURLProtocol.capturedAuthHeader = nil
        PublicBoardURLProtocol.capturedNativeHeader = nil
        PublicBoardURLProtocol.status = 200
        PublicBoardURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    @Test func boardGetsAndUnwrapsEnvelope() async throws {
        reset()
        PublicBoardURLProtocol.responseBody = Data("""
        {"ok":true,"board":{"handle":"amara","ownerProfilePublic":true,"ownerAvatarUrl":"https://cdn/a.jpg","boardName":"Summer hair","boardSlug":"summer-hair","looks":[{"id":"lk_1","name":"Balayage","imageUrl":"https://cdn/l.jpg","href":"/looks/lk_1"}],"viewer":{"isOwn":false,"followingOwner":true}}}
        """.utf8)

        let board = try await makeService().board(handle: "amara", slug: "summer-hair")

        #expect(PublicBoardURLProtocol.capturedPath == "/api/v1/u/amara/boards/summer-hair")
        #expect(PublicBoardURLProtocol.capturedMethod == "GET")
        #expect(PublicBoardURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(PublicBoardURLProtocol.capturedNativeHeader == "ios")

        #expect(board?.handle == "amara")
        #expect(board?.ownerProfilePublic == true)
        #expect(board?.ownerAvatarUrl == "https://cdn/a.jpg")
        #expect(board?.boardName == "Summer hair")
        #expect(board?.boardSlug == "summer-hair")
        #expect(board?.looks.count == 1)
        #expect(board?.looks.first?.id == "lk_1")
        #expect(board?.looks.first?.name == "Balayage")
        #expect(board?.looks.first?.href == "/looks/lk_1")
        #expect(board?.viewer.isOwn == false)
        #expect(board?.viewer.followingOwner == true)
    }

    @Test func boardDefaultsMissingKeysDefensively() async throws {
        reset()
        // A minimal / older backend payload — only handle + one look id.
        PublicBoardURLProtocol.responseBody = Data("""
        {"ok":true,"board":{"handle":"amara","looks":[{"id":"lk_2"}]}}
        """.utf8)

        let board = try await makeService().board(handle: "amara", slug: "s")

        #expect(board?.ownerProfilePublic == false)
        #expect(board?.ownerAvatarUrl == nil)
        #expect(board?.boardName == "Board")
        #expect(board?.looks.first?.name == "Look")
        #expect(board?.looks.first?.href == "/looks/lk_2")
        #expect(board?.viewer.isOwn == false)
        #expect(board?.viewer.followingOwner == false)
    }

    @Test func boardReturnsNilOn404() async throws {
        reset()
        PublicBoardURLProtocol.status = 404
        PublicBoardURLProtocol.responseBody = Data("{\"ok\":false,\"error\":\"Board not found.\"}".utf8)

        let board = try await makeService().board(handle: "amara", slug: "ghost")

        #expect(PublicBoardURLProtocol.capturedPath == "/api/v1/u/amara/boards/ghost")
        #expect(board == nil)
    }

    @Test func boardThrowsOnOtherServerError() async throws {
        reset()
        PublicBoardURLProtocol.status = 500
        PublicBoardURLProtocol.responseBody = Data("{\"ok\":false,\"error\":\"Failed to load board.\"}".utf8)

        do {
            _ = try await makeService().board(handle: "amara", slug: "summer-hair")
            Issue.record("expected board(handle:slug:) to throw on a 500")
        } catch let error as APIError {
            guard case let .server(status, _, _) = error else {
                Issue.record("expected APIError.server, got \(error)")
                return
            }
            #expect(status == 500)
        }
    }
}
