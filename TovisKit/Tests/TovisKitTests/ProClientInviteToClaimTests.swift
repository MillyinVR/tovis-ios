import Foundation
import Testing
@testable import TovisKit

// Proves ProClientsService.inviteToClaim(clientId:) POSTs the booking-less claim
// invite to the right route and decodes the invite + delivery summary.

/// Records the outgoing request and serves a canned response.
final class InviteToClaimURLProtocol: URLProtocol {
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

@Suite(.serialized) struct ProClientInviteToClaimTests {
    private func makeService() -> ProClientsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InviteToClaimURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.invite.tests")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProClientsService(api: api)
    }

    @Test func postsToTheInviteRouteAndDecodesTheSummary() async throws {
        InviteToClaimURLProtocol.capturedPath = nil
        InviteToClaimURLProtocol.capturedMethod = nil
        InviteToClaimURLProtocol.status = 200
        InviteToClaimURLProtocol.responseBody = Data("""
        {"ok":true,
         "invite":{"id":"invite_1","token":"rawtok_1","status":"PENDING",
         "invitedName":"Imported Client","invitedEmail":"client@example.com",
         "invitedPhone":null,"preferredContactMethod":"EMAIL"},
         "inviteDelivery":{"attempted":true,"queued":true,"href":"/claim/rawtok_1"}}
        """.utf8)

        let result = try await makeService().inviteToClaim(clientId: "client_1")

        #expect(InviteToClaimURLProtocol.capturedPath == "/api/v1/pro/clients/client_1/invite")
        #expect(InviteToClaimURLProtocol.capturedMethod == "POST")
        #expect(result.invite.id == "invite_1")
        #expect(result.invite.token == "rawtok_1")
        #expect(result.invite.invitedEmail == "client@example.com")
        #expect(result.inviteDelivery.queued == true)
    }

    @Test func decodesAContactlessInviteThatWasNotDelivered() async throws {
        InviteToClaimURLProtocol.status = 200
        InviteToClaimURLProtocol.responseBody = Data("""
        {"ok":true,
         "invite":{"id":"invite_2","token":"rawtok_2","status":"PENDING",
         "invitedName":"No Contact","invitedEmail":null,"invitedPhone":null,
         "preferredContactMethod":null},
         "inviteDelivery":{"attempted":false,"queued":false,"href":null}}
        """.utf8)

        let result = try await makeService().inviteToClaim(clientId: "client_2")

        #expect(result.invite.token == "rawtok_2")
        #expect(result.inviteDelivery.queued == false)
    }
}
