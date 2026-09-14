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

    /// 🔴 Read this next to `decodesEveryBlockerTheServerCanSend`. On its own this
    /// test is what made a real break invisible for twenty days: web #997 renamed
    /// two blockers, they landed here as `.unknown`, and the fallback this asserts
    /// worked perfectly — a checklist row with generic copy and no destination.
    /// The fallback is for a blocker the app has not SHIPPED support for yet; the
    /// fixture test below is what proves the app knows the ones that exist today.
    @Test func toleratesUnknownBlocker() async throws {
        reset("{\"ok\":true,\"readiness\":{\"ok\":false,\"blockers\":[\"SOME_FUTURE_BLOCKER\"]}}")

        let readiness = try await makeService().readiness()

        #expect(readiness.blockers == [.unknown])
    }

    /// The contract fixture (`proReadiness.json`) holds the server's whole blocker
    /// vocabulary, and the cross-repo validator holds the fixture to the generated
    /// API schema. Decoding it here closes the loop: not ONE of these may land on
    /// `.unknown`, so a blocker renamed on web fails in tovis-app CI
    /// (validate-fixtures) and again here.
    @Test func decodesEveryBlockerTheServerCanSend() throws {
        let data = try fixture("proReadiness")
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let blocked = try #require(root["blocked"] as? [String: Any])

        let readiness = try JSONDecoder().decode(
            ProReadinessResponse.self,
            from: JSONSerialization.data(withJSONObject: blocked)
        ).readiness

        #expect(
            readiness.blockers == [
                .noActiveOffering,
                .noBookableLocation,
                .salonMissingAddress,
                .mobileMissingBaseConfig,
                .locationMissingTimezone,
                .locationMissingWorkingHours,
                .locationMissingGeo,
                .offeringMissingSalonPriceOrDuration,
                .offeringMissingMobilePriceOrDuration,
                .stripeNotReady,
                .verificationBarred,
                .licenseExpired,
            ]
        )
        #expect(!readiness.blockers.contains(.unknown))
    }

    /// The ready arm of the same fixture — `ok: true` carries different keys
    /// entirely, so it is a separate shape, not a variation.
    @Test func decodesTheReadyArmOfTheFixture() throws {
        let data = try fixture("proReadiness")
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let ready = try #require(root["ready"] as? [String: Any])

        let readiness = try JSONDecoder().decode(
            ProReadinessResponse.self,
            from: JSONSerialization.data(withJSONObject: ready)
        ).readiness

        #expect(readiness.isReady)
        #expect(readiness.blockers.isEmpty)
    }
}
