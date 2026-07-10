import Foundation
import Testing
@testable import TovisKit

// Proves the pro waitlist-outreach read method hits the right route and decodes
// the grouped feed (an existing web route — an iOS-only port):
//   • waitlistOutreach → GET /api/v1/pro/waitlist → decodes services + entries + total
// The nested entries carry the FIFO rank, server-formatted preference label, and
// join instant; a missing avatar decodes to nil.

/// Records the outgoing request and serves a canned envelope.
final class ProWaitlistURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct ProWaitlistTests {
    private static let feedJSON = """
    {
      "ok": true,
      "total": 3,
      "services": [
        {
          "serviceId": "svc_1",
          "serviceName": "Balayage",
          "entries": [
            {"rank": 1, "waitlistEntryId": "wle_1", "clientName": "Dana Rivers",
             "avatarUrl": "https://cdn.tovis.me/a.jpg", "preferenceLabel": "Morning",
             "joinedAt": "2026-07-05T14:00:00.000Z"},
            {"rank": 2, "waitlistEntryId": "wle_2", "clientName": "Client",
             "avatarUrl": null, "preferenceLabel": "Any time",
             "joinedAt": "2026-07-06T14:00:00.000Z"}
          ]
        },
        {
          "serviceId": "svc_2",
          "serviceName": "Cut",
          "entries": [
            {"rank": 1, "waitlistEntryId": "wle_3", "clientName": "Sam Lee",
             "avatarUrl": null, "preferenceLabel": "9:00 AM–12:00 PM",
             "joinedAt": "2026-07-07T14:00:00.000Z"}
          ]
        }
      ]
    }
    """

    private func makeService() async -> ProScheduleService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProWaitlistURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.waitlist.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProScheduleService(api: api)
    }

    private func reset(response: String) {
        ProWaitlistURLProtocol.capturedPath = nil
        ProWaitlistURLProtocol.capturedMethod = nil
        ProWaitlistURLProtocol.responseBody = Data(response.utf8)
    }

    @Test func waitlistOutreachGetsAndDecodesGroups() async throws {
        reset(response: Self.feedJSON)

        let outreach = try await makeService().waitlistOutreach()

        #expect(ProWaitlistURLProtocol.capturedPath == "/api/v1/pro/waitlist")
        #expect(ProWaitlistURLProtocol.capturedMethod == "GET")

        #expect(outreach.total == 3)
        #expect(outreach.isEmpty == false)
        #expect(outreach.services.count == 2)

        let balayage = try #require(outreach.services.first)
        #expect(balayage.id == "svc_1")
        #expect(balayage.serviceName == "Balayage")
        #expect(balayage.entries.count == 2)

        let first = try #require(balayage.entries.first)
        #expect(first.rank == 1)
        #expect(first.id == "wle_1")
        #expect(first.clientName == "Dana Rivers")
        #expect(first.avatarUrl == "https://cdn.tovis.me/a.jpg")
        #expect(first.preferenceLabel == "Morning")

        // A missing avatar decodes to nil.
        #expect(balayage.entries.last?.avatarUrl == nil)
    }

    @Test func waitlistOutreachDecodesEmptyFeed() async throws {
        reset(response: "{\"ok\":true,\"total\":0,\"services\":[]}")

        let outreach = try await makeService().waitlistOutreach()

        #expect(outreach.total == 0)
        #expect(outreach.isEmpty)
        #expect(outreach.services.isEmpty)
    }
}
