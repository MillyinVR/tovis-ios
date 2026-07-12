import Foundation
import Testing
@testable import TovisKit

// Proves the token-addressed public claim surface hits the right route:
//   • claimContext(token:) → GET /public/claim/{token} → ClaimContextResponse
//     (nil on 404). The GET is public-read (unauthenticated); a 404 means "no such
//     claim link" (surfaced as nil), any other non-2xx throws.

/// Records the outgoing request and serves a canned response.
final class ClaimURLProtocol: URLProtocol {
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

@Suite(.serialized) struct ClaimServiceTests {
    private func makeService() -> ClaimService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaimURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.claim.tests")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ClaimService(api: api)
    }

    private func reset() {
        ClaimURLProtocol.capturedPath = nil
        ClaimURLProtocol.capturedMethod = nil
        ClaimURLProtocol.status = 200
        ClaimURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    @Test func claimContextGetsAndDecodesBookingContext() async throws {
        reset()
        ClaimURLProtocol.responseBody = Data("""
        {"ok":true,"state":"ready","invitedName":"Tori Morales",
         "invitedEmail":"tori@example.com","invitedPhone":"+16195551234",
         "professionalName":"Glow Studio",
         "booking":{"serviceName":"Balayage","professionalName":"Glow Studio",
         "scheduledFor":"2026-05-01T17:00:00.000Z","timeZone":"America/Los_Angeles",
         "locationLabel":"Studio A, San Diego"}}
        """.utf8)

        let context = try await makeService().claimContext(token: "tok_1")

        #expect(ClaimURLProtocol.capturedPath == "/api/v1/public/claim/tok_1")
        #expect(ClaimURLProtocol.capturedMethod == "GET")

        #expect(context?.state == "ready")
        #expect(context?.invitedName == "Tori Morales")
        #expect(context?.invitedEmail == "tori@example.com")
        #expect(context?.invitedPhone == "+16195551234")
        #expect(context?.professionalName == "Glow Studio")
        #expect(context?.booking?.serviceName == "Balayage")
        #expect(context?.booking?.professionalName == "Glow Studio")
        #expect(context?.booking?.scheduledFor == "2026-05-01T17:00:00.000Z")
        #expect(context?.booking?.timeZone == "America/Los_Angeles")
        #expect(context?.booking?.locationLabel == "Studio A, San Diego")
    }

    @Test func claimContextDecodesBooklessClaimWithPro() async throws {
        reset()
        // A booking-less pro-facing claim: no booking, but a pro name to head it.
        ClaimURLProtocol.responseBody = Data("""
        {"ok":true,"state":"ready","invitedName":"Tori Morales",
         "invitedEmail":"tori@example.com","invitedPhone":null,
         "professionalName":"Glow Studio","booking":null}
        """.utf8)

        let context = try await makeService().claimContext(token: "tok_bookless")

        #expect(context?.state == "ready")
        #expect(context?.invitedName == "Tori Morales")
        #expect(context?.professionalName == "Glow Studio")
        #expect(context?.booking == nil)
    }

    @Test func claimContextDecodesBooklessProlessClaim() async throws {
        reset()
        // Cold self-serve orphan: no booking AND no pro.
        ClaimURLProtocol.responseBody = Data("""
        {"ok":true,"state":"ready","invitedName":null,"invitedEmail":"tori@example.com",
         "invitedPhone":null,"professionalName":null,"booking":null}
        """.utf8)

        let context = try await makeService().claimContext(token: "tok_orphan")

        #expect(context?.state == "ready")
        #expect(context?.professionalName == nil)
        #expect(context?.booking == nil)
    }

    @Test func claimContextDecodesNullContactAndSchedule() async throws {
        reset()
        ClaimURLProtocol.responseBody = Data("""
        {"ok":true,"state":"revoked","invitedName":null,"invitedEmail":null,
         "invitedPhone":null,"professionalName":"your professional",
         "booking":{"serviceName":null,
         "professionalName":"your professional","scheduledFor":null,
         "timeZone":"UTC","locationLabel":null}}
        """.utf8)

        let context = try await makeService().claimContext(token: "tok_2")

        #expect(context?.state == "revoked")
        #expect(context?.invitedName == nil)
        #expect(context?.booking?.serviceName == nil)
        #expect(context?.booking?.scheduledFor == nil)
        #expect(context?.booking?.professionalName == "your professional")
    }

    @Test func claimContextReturnsNilOn404() async throws {
        reset()
        ClaimURLProtocol.status = 404
        ClaimURLProtocol.responseBody = Data("{\"ok\":false,\"error\":\"Claim link not found.\"}".utf8)

        let context = try await makeService().claimContext(token: "ghost")

        #expect(ClaimURLProtocol.capturedPath == "/api/v1/public/claim/ghost")
        #expect(context == nil)
    }

    @Test func claimContextThrowsOnOtherServerError() async throws {
        reset()
        ClaimURLProtocol.status = 500
        ClaimURLProtocol.responseBody = Data("{\"ok\":false,\"error\":\"Internal server error\"}".utf8)

        do {
            _ = try await makeService().claimContext(token: "tok_1")
            Issue.record("expected claimContext to throw on a 500")
        } catch let error as APIError {
            guard case let .server(status, _, _) = error else {
                Issue.record("expected APIError.server, got \(error)")
                return
            }
            #expect(status == 500)
        }
    }
}
