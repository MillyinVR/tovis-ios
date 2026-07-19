import Foundation
import Testing
@testable import TovisKit

// Pins the wire contract of the client→pro follow control.
//
// This file exists because of what its absence allowed: `LooksService` sent
// **DELETE** to unfollow, `/api/v1/pros/{id}/follow` has only GET and POST
// handlers, and so every unfollow from the looks feed, the look detail and the
// pro profile returned 405. It built, it typechecked, and 795 tests passed. The
// only thing that would have caught it is an assertion on the METHOD — which is
// what these are. (Found by driving the simulator against a real dev server and
// reading the request out of the server log, not off the screen.)

/// Its own static storage so it never races the other suites' mocks.
final class ProFollowURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var responseBody = Data("{}".utf8)
    nonisolated(unsafe) static var responseStatus = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: Self.responseStatus, httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct ProFollowServiceTests {

    private func makeService() async -> LooksService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProFollowURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.profollow.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return LooksService(api: api)
    }

    private func reset(_ body: String, status: Int = 200) {
        ProFollowURLProtocol.capturedPath = nil
        ProFollowURLProtocol.capturedMethod = nil
        ProFollowURLProtocol.responseBody = Data(body.utf8)
        ProFollowURLProtocol.responseStatus = status
    }

    /// 🔴 The regression. The route is a blind toggle — `toggleProFollow` on the
    /// server flips whatever it currently holds — so BOTH directions are a POST.
    /// Sending DELETE to unfollow is what 405'd.
    @Test func unfollowPostsRatherThanDeleting() async throws {
        reset(#"{"following":false,"followerCount":41}"#)
        let service = await makeService()

        // The viewer is following and taps again to unfollow: same request.
        let state = try await service.toggleFollow(professionalId: "pro_1")

        #expect(ProFollowURLProtocol.capturedMethod == "POST")  // never DELETE
        #expect(ProFollowURLProtocol.capturedPath == "/api/v1/pros/pro_1/follow")
        #expect(state.following == false)
        #expect(state.followerCount == 41)
    }

    @Test func followPostsToTheSameRoute() async throws {
        reset(#"{"following":true,"followerCount":42}"#)
        let service = await makeService()

        let state = try await service.toggleFollow(professionalId: "pro_1")

        #expect(ProFollowURLProtocol.capturedMethod == "POST")
        #expect(ProFollowURLProtocol.capturedPath == "/api/v1/pros/pro_1/follow")
        #expect(state.following == true)
        #expect(state.followerCount == 42)
    }

    /// The server's answer is the authority, which is the whole reason a blind
    /// toggle returns one — the caller cannot know what it flipped.
    @Test func followStateHydrateIsAGet() async throws {
        reset(#"{"following":true,"followerCount":7}"#)
        let service = await makeService()

        let state = try await service.followState(professionalId: "pro_9")

        #expect(ProFollowURLProtocol.capturedMethod == "GET")
        #expect(ProFollowURLProtocol.capturedPath == "/api/v1/pros/pro_9/follow")
        #expect(state.following == true)
        #expect(state.followerCount == 7)
    }

    @Test func aRefusedToggleSurfacesAsAThrownError() async throws {
        reset(#"{"error":"Method Not Allowed"}"#, status: 405)
        let service = await makeService()

        await #expect(throws: (any Error).self) {
            _ = try await service.toggleFollow(professionalId: "pro_1")
        }
    }
}
