import Foundation
import Testing
@testable import TovisKit

// W5 chart consent, pro side:
//   • chartShare          → GET  /pro/clients/{id}/chart-share
//   • requestChartAccess  → POST /pro/clients/{id}/chart-share
//
// Plus the one piece of judgement the model carries: whether to render the ask.
// That answer comes from the SERVER (`canRequest`), never from `status`, because
// the re-request cooldown after a revoke is a duration this app does not know.

/// Own statics, so this suite can't collide with a sibling suite's mock.
final class ProChartShareURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
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

@Suite(.serialized) struct ProClientChartShareTests {
    private func makeService() async -> ProClientsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProChartShareURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.chartshare.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProClientsService(api: api)
    }

    private func reset(status: Int = 200, body: String) {
        ProChartShareURLProtocol.capturedPath = nil
        ProChartShareURLProtocol.capturedMethod = nil
        ProChartShareURLProtocol.status = status
        ProChartShareURLProtocol.responseBody = Data(body.utf8)
    }

    @Test func chartShareGetsTheShareRoute() async throws {
        reset(body: #"{"ok":true,"chartShare":{"status":"REQUESTED","canRequest":false,"requestBlockedReason":"REQUEST_PENDING"}}"#)

        let share = try await makeService().chartShare(clientId: "cl_1")

        #expect(ProChartShareURLProtocol.capturedPath == "/api/v1/pro/clients/cl_1/chart-share")
        #expect(ProChartShareURLProtocol.capturedMethod == "GET")
        #expect(share.status == .requested)
        #expect(share.proCanAsk == false)
        #expect(share.blockedCopy?.contains("waiting on them") == true)
    }

    @Test func requestChartAccessPostsToTheSameRoute() async throws {
        reset(body: #"{"ok":true,"chartShare":{"status":"REQUESTED"}}"#)

        let share = try await makeService().requestChartAccess(clientId: "cl_1")

        #expect(ProChartShareURLProtocol.capturedPath == "/api/v1/pro/clients/cl_1/chart-share")
        #expect(ProChartShareURLProtocol.capturedMethod == "POST")
        #expect(share.status == .requested)
    }

    // A pair with no row at all: nobody has asked, nobody has shared.
    @Test func aMissingStatusIsNotAnAnswer() async throws {
        reset(body: #"{"ok":true,"chartShare":{"status":null,"canRequest":true,"requestBlockedReason":null}}"#)

        let share = try await makeService().chartShare(clientId: "cl_1")

        #expect(share.status == nil)
        #expect(share.proCanAsk)
        #expect(share.blockedCopy == nil)
    }

    // 🔴 The drift this guards: REVOKED is re-askable in general, so deriving
    // "can I ask?" from `status` would show a live button during the cooldown —
    // and the POST would answer 409 the moment the pro pressed it.
    @Test func aRevokedShareInCooldownStillHidesTheAsk() async throws {
        reset(body: #"{"ok":true,"chartShare":{"status":"REVOKED","canRequest":false,"requestBlockedReason":"COOLDOWN"}}"#)

        let share = try await makeService().chartShare(clientId: "cl_1")

        #expect(share.status == .revoked)
        #expect(share.proCanAsk == false)
        #expect(share.blockedCopy?.contains("recently turned off") == true)
    }

    @Test func aRevokedShareOutOfCooldownOffersTheAsk() async throws {
        reset(body: #"{"ok":true,"chartShare":{"status":"REVOKED","canRequest":true}}"#)

        let share = try await makeService().chartShare(clientId: "cl_1")

        #expect(share.proCanAsk)
        #expect(share.blockedCopy == nil)
    }

    // An older server that doesn't send `canRequest`. Offering the ask is the
    // safe default — the POST is the real gate, and hiding the only way out of
    // the refusal would strand the pro with nothing to press.
    @Test func anAbsentCanRequestFallsBackToOfferingTheAsk() async throws {
        reset(body: #"{"ok":true,"chartShare":{"status":null}}"#)

        let share = try await makeService().chartShare(clientId: "cl_1")

        #expect(share.proCanAsk)
    }

    // 🔴 A future server code this build cannot name. Without the fallback the
    // screen renders neither a button (proCanAsk is false) nor a reason
    // (no copy matched) — the pro stares at the refusal with nothing to do.
    @Test func anUnknownBlockReasonStillExplainsItself() async throws {
        reset(body: #"{"ok":true,"chartShare":{"status":"REVOKED","canRequest":false,"requestBlockedReason":"SOME_FUTURE_RULE"}}"#)

        let share = try await makeService().chartShare(clientId: "cl_1")

        #expect(share.proCanAsk == false)
        #expect(share.blockedCopy != nil)
    }

    // The mirror of the rule above: copy appears only when the ask does not.
    @Test func aStaleBlockReasonIsIgnoredOnceTheAskIsAllowed() async throws {
        reset(body: #"{"ok":true,"chartShare":{"status":"REVOKED","canRequest":true,"requestBlockedReason":"COOLDOWN"}}"#)

        let share = try await makeService().chartShare(clientId: "cl_1")

        #expect(share.proCanAsk)
        #expect(share.blockedCopy == nil)
    }

    // The refusal has to reach the caller as a `code`, not as prose: the pro
    // chart view branches on CHART_NOT_SHARED, and NO_CLIENT_RELATIONSHIP
    // deliberately answers the same status with different copy.
    @Test func aRefusalCarriesItsCode() async throws {
        reset(
            status: 409,
            body: #"{"ok":false,"error":"You already have a request waiting with this client.","code":"REQUEST_PENDING"}"#
        )

        await #expect(throws: APIError.self) {
            try await makeService().requestChartAccess(clientId: "cl_1")
        }

        do {
            _ = try await makeService().requestChartAccess(clientId: "cl_1")
        } catch let error as APIError {
            guard case let .server(status, message, code) = error else {
                Issue.record("expected .server, got \(error)")
                return
            }
            #expect(status == 409)
            #expect(code == "REQUEST_PENDING")
            #expect(message == "You already have a request waiting with this client.")
        }
    }
}
