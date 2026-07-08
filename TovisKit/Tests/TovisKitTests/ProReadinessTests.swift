import Foundation
import Testing
@testable import TovisKit

// Proves ProReadinessService.readiness() hits GET /pro/readiness as an
// authenticated native request and decodes both arms of the readiness union —
// including tolerating a blocker string the app doesn't know yet.

/// Serves a canned readiness envelope and records the outgoing request.
final class ProReadinessURLProtocol: URLProtocol {
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
            url: request.url!,
            statusCode: Self.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct ProReadinessTests {
    private func makeService() async -> ProReadinessService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProReadinessURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.readiness.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProReadinessService(api: api)
    }

    private func reset(_ body: String) {
        ProReadinessURLProtocol.capturedPath = nil
        ProReadinessURLProtocol.capturedMethod = nil
        ProReadinessURLProtocol.capturedAuthHeader = nil
        ProReadinessURLProtocol.capturedNativeHeader = nil
        ProReadinessURLProtocol.status = 200
        ProReadinessURLProtocol.responseBody = Data(body.utf8)
    }

    @Test func getsReadinessAsAuthenticatedNativeRequest() async throws {
        reset("{\"ok\":true,\"readiness\":{\"ok\":true,\"liveModes\":[\"SALON\"],\"readyLocationIds\":[\"loc_1\"]}}")

        let readiness = try await makeService().readiness()

        #expect(ProReadinessURLProtocol.capturedPath == "/api/v1/pro/readiness")
        #expect(ProReadinessURLProtocol.capturedMethod == "GET")
        #expect(ProReadinessURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(ProReadinessURLProtocol.capturedNativeHeader == "ios")

        #expect(readiness.isReady)
        #expect(readiness.blockers.isEmpty)
    }

    @Test func decodesBlockedReadiness() async throws {
        reset("{\"ok\":true,\"readiness\":{\"ok\":false,\"blockers\":[\"NO_ACTIVE_OFFERING\",\"STRIPE_NOT_READY\"]}}")

        let readiness = try await makeService().readiness()

        #expect(!readiness.isReady)
        #expect(readiness.blockers == [.noActiveOffering, .stripeNotReady])
    }

    @Test func toleratesUnknownBlocker() async throws {
        reset("{\"ok\":true,\"readiness\":{\"ok\":false,\"blockers\":[\"SOME_FUTURE_BLOCKER\"]}}")

        let readiness = try await makeService().readiness()

        #expect(readiness.blockers == [.unknown])
    }
}
