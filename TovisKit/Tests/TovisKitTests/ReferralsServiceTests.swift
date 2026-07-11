import Foundation
import Testing
@testable import TovisKit

// Proves the client Referrals surface hits the right routes and decodes the list:
//   • list()          → GET  /client/referrals            → { ok, referrals: [...] }
//   • confirm(id:)     → POST /client/referrals/{id}/confirm
//   • decline(id:)     → POST /client/referrals/{id}/decline
// Mirrors the inline `Referral` shape + web actions in ReferralListClient.tsx.

/// Records the outgoing request and serves a canned envelope.
final class ReferralsURLProtocol: URLProtocol {
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

@Suite(.serialized) struct ReferralsServiceTests {
    private func makeService() async -> ReferralsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReferralsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.referrals.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ReferralsService(api: api)
    }

    private func reset() {
        ReferralsURLProtocol.capturedPath = nil
        ReferralsURLProtocol.capturedMethod = nil
        ReferralsURLProtocol.status = 200
        ReferralsURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    // MARK: - list()

    @Test func listGetsAndDecodes() async throws {
        reset()
        ReferralsURLProtocol.responseBody = Data("""
        {"ok":true,"referrals":[
          {"id":"rf_1","status":"CONVERTED","referredFirstName":"Maya","referredAvatarUrl":"https://cdn/a.jpg","proName":"Tori Morales","proHref":"/p/tori","rewardTier":"CREDIT","rewardValue":10,"rewardAppliedAt":null,"confirmedAt":"2026-07-02T00:00:00.000Z","convertedAt":"2026-07-03T00:00:00.000Z","expiresAt":"2026-08-01T00:00:00.000Z","createdAt":"2026-07-01T00:00:00.000Z"},
          {"id":"rf_2","status":"PENDING","referredFirstName":"Someone","referredAvatarUrl":null,"proName":null,"proHref":null,"rewardTier":null,"rewardValue":null,"rewardAppliedAt":null,"confirmedAt":null,"convertedAt":null,"expiresAt":"2026-08-01T00:00:00.000Z","createdAt":"2026-07-04T00:00:00.000Z"}
        ]}
        """.utf8)

        let referrals = try await makeService().list()

        #expect(ReferralsURLProtocol.capturedPath == "/api/v1/client/referrals")
        #expect(ReferralsURLProtocol.capturedMethod == "GET")

        #expect(referrals.count == 2)

        let converted = try #require(referrals.first)
        #expect(converted.id == "rf_1")
        #expect(converted.status == "CONVERTED")
        #expect(converted.referredFirstName == "Maya")
        #expect(converted.referredAvatarUrl == "https://cdn/a.jpg")
        #expect(converted.proName == "Tori Morales")
        #expect(converted.proHref == "/p/tori")
        #expect(converted.rewardTier == "CREDIT")
        #expect(converted.rewardValue == 10)
        #expect(converted.isPending == false)

        let pending = referrals[1]
        #expect(pending.status == "PENDING")
        #expect(pending.referredAvatarUrl == nil)
        #expect(pending.proName == nil)
        #expect(pending.rewardTier == nil)
        #expect(pending.rewardValue == nil)
        #expect(pending.isPending == true)
    }

    @Test func listDecodesEmpty() async throws {
        reset()
        ReferralsURLProtocol.responseBody = Data("{\"ok\":true,\"referrals\":[]}".utf8)
        let referrals = try await makeService().list()
        #expect(referrals.isEmpty)
    }

    // MARK: - confirm / decline

    @Test func confirmPostsToRoute() async throws {
        reset()
        ReferralsURLProtocol.responseBody = Data("{\"ok\":true,\"confirmed\":true}".utf8)

        try await makeService().confirm(id: "rf_2")

        #expect(ReferralsURLProtocol.capturedPath == "/api/v1/client/referrals/rf_2/confirm")
        #expect(ReferralsURLProtocol.capturedMethod == "POST")
    }

    @Test func declinePostsToRoute() async throws {
        reset()
        ReferralsURLProtocol.responseBody = Data("{\"ok\":true,\"declined\":true}".utf8)

        try await makeService().decline(id: "rf_2")

        #expect(ReferralsURLProtocol.capturedPath == "/api/v1/client/referrals/rf_2/decline")
        #expect(ReferralsURLProtocol.capturedMethod == "POST")
    }

    @Test func confirmThrowsWhenNoLongerPending() async throws {
        reset()
        ReferralsURLProtocol.status = 409
        ReferralsURLProtocol.responseBody = Data("{\"ok\":false,\"error\":\"Referral is no longer pending.\"}".utf8)

        do {
            try await makeService().confirm(id: "rf_stale")
            Issue.record("expected confirm(id:) to throw on a 409")
        } catch let error as APIError {
            guard case let .server(status, _, _) = error else {
                Issue.record("expected APIError.server, got \(error)")
                return
            }
            #expect(status == 409)
        }
    }
}
