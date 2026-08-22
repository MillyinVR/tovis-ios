import Foundation
import Testing
@testable import TovisKit

// Pins the wire contract of POST /api/v1/pro/schedule/publish, specifically the
// STATUS CODE — which is the whole behaviour this client keys off.
//
// `ProLocationsService.publish()` calls `requestVoid`, which throws on any
// non-2xx and discards the body. `ProLocationsView.publish()` (Tovis app target)
// does:
//
//     do { try await …publish(); await load() }
//     catch let apiError as APIError { actionError = apiError.userMessage }
//
// so a thrown error does TWO things: it shows an error message, and it skips
// `await load()`, leaving the locations list rendering stale draft state.
//
// That is exactly what used to happen on the happy-ish path. tovis-app returned
// **422** after its publish transaction had already COMMITTED, whenever the pro
// was still not bookable for an unrelated reason (typically "no services yet").
// The location WAS published — measured 0 → 1 bookable across that same call —
// but the app told the pro it had failed, and never refreshed.
//
// tovis-app#979 (`d796a14a`) fixed it server-side, which repairs this already
// shipped binary with no app update. These tests pin both halves so a future
// change to that route cannot silently reintroduce it.
//
// Every body below is a VERBATIM capture from the real running route, driven in
// a browser against a local server on 2026-08-22 — not hand-written JSON.

/// Its own static storage so it never races the other suites' mocks.
final class ProLocationsPublishURLProtocol: URLProtocol {
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

@Suite(.serialized) struct ProLocationsPublishTests {

    private func makeService() async -> ProLocationsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProLocationsPublishURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.prolocationspublish.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProLocationsService(api: api)
    }

    private func reset(_ body: String, status: Int) {
        ProLocationsPublishURLProtocol.capturedPath = nil
        ProLocationsPublishURLProtocol.capturedMethod = nil
        ProLocationsPublishURLProtocol.responseBody = Data(body.utf8)
        ProLocationsPublishURLProtocol.responseStatus = status
    }

    /// 🔴 THE REGRESSION GUARD. Publish succeeded, the pro is still not bookable
    /// because they have no services yet. Must NOT throw — if it does, the app
    /// shows a false error AND skips `await load()`.
    @Test func publishedButStillNotBookableDoesNotThrow() async throws {
        reset(
            #"{"ok":true,"liveModes":[],"locationsPublished":1,"scheduleConfigVersion":1,"blockedLocations":[],"blockers":["NO_ACTIVE_OFFERING"]}"#,
            status: 200
        )
        let service = await makeService()

        try await service.publish()

        #expect(ProLocationsPublishURLProtocol.capturedMethod == "POST")
        #expect(ProLocationsPublishURLProtocol.capturedPath == "/api/v1/pro/schedule/publish")
    }

    /// The pre-fix response, kept so the failure mode stays legible: the same
    /// successful publish used to arrive as a 422 and DID throw.
    @Test func theOldPostCommit422WouldHaveThrown() async throws {
        reset(
            #"{"ok":false,"error":"Locations were published, but the professional is still not ready for booking.","locationsPublished":1,"scheduleConfigVersion":1,"blockers":["NO_ACTIVE_OFFERING"],"blockedLocations":[]}"#,
            status: 422
        )
        let service = await makeService()

        await #expect(throws: (any Error).self) {
            try await service.publish()
        }
    }

    /// A GENUINE refusal — nothing was written because the only draft location
    /// is unpublishable — must still throw, so the pro still sees "Couldn't
    /// publish". The fix deliberately left this branch a 422.
    @Test func aRealRefusalStillThrows() async throws {
        reset(
            #"{"ok":false,"error":"Schedule cannot be published until all location blockers are resolved.","blockedLocations":[{"ok":false,"locationId":"cmt3orab30003pom2qn6d1f2g","blockers":["LOCATION_MISSING_TIMEZONE"]}]}"#,
            status: 422
        )
        let service = await makeService()

        await #expect(throws: (any Error).self) {
            try await service.publish()
        }
    }

    /// Nothing left to publish — the branch a repeat call hits. Also a success.
    @Test func nothingToPublishDoesNotThrow() async throws {
        reset(
            #"{"ok":true,"liveModes":[],"locationsPublished":0,"scheduleConfigVersion":null,"blockers":["NO_ACTIVE_OFFERING"]}"#,
            status: 200
        )
        let service = await makeService()

        try await service.publish()
    }
}
