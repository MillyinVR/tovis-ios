import Foundation
import Testing
@testable import TovisKit

// Proves the token-addressed claim surface hits the right routes:
//   • claimContext(token:) → GET /public/claim/{token} → ClaimContextResponse
//     (nil on 404). The GET is public-read (unauthenticated); a 404 means "no such
//     claim link" (surfaced as nil), any other non-2xx throws.
//   • acceptClaim(token:) → POST /pro/invites/{token}/accept → ClaimAcceptOutcome.
//     Authenticated. Every documented failure is an outcome, not a throw.
//
// ⚠️ The accept bodies below are pinned VERBATIM from the live route (driven
// locally 2026-07-16 with a real minted client JWT against real seeded invites) —
// NOT from what the reader assumes. A test written from the same assumption as the
// code proves nothing about the wire: that is exactly how the OTP cooldown shipped
// broken (both the reader and its mocks agreed on a top-level `retryAfterSeconds`
// the API has never emitted). If these bodies drift, re-drive the route.
//
// The statuses here are deliberately ambiguous — 404 is NOT_FOUND *or*
// CLIENT_NOT_FOUND, 409 is ALREADY_CLAIMED *or* CLIENT_MISMATCH *or* CONFLICT — so
// these also pin that the mapping keys on `code`, never the status.

/// Records the outgoing request and serves a canned response.
final class ClaimURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedAuthorization: String?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedAuthorization = request.value(forHTTPHeaderField: "Authorization")

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
        ClaimURLProtocol.capturedAuthorization = nil
        ClaimURLProtocol.status = 200
        ClaimURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    /// Drives `acceptClaim` against a verbatim-captured failure body.
    private func outcome(status: Int, body: String) async throws -> ClaimAcceptOutcome {
        reset()
        ClaimURLProtocol.status = status
        ClaimURLProtocol.responseBody = Data(body.utf8)
        return try await makeService().acceptClaim(token: "tok_1")
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

    // MARK: - acceptClaim

    @Test func acceptClaimPostsAuthenticatedToTheInviteAcceptRoute() async throws {
        reset()
        ClaimURLProtocol.responseBody = Data("{\"ok\":true,\"bookingId\":\"bk_1\"}".utf8)

        let result = try await makeService().acceptClaim(token: "tok_1")

        // Despite the /pro/ path this IS the client-side accept (requireClient).
        #expect(ClaimURLProtocol.capturedPath == "/api/v1/pro/invites/tok_1/accept")
        #expect(ClaimURLProtocol.capturedMethod == "POST")
        #expect(result == .claimed(bookingId: "bk_1"))
    }

    @Test func acceptClaimDecodesBooklessSuccess() async throws {
        reset()
        // Verbatim from the live route's booking-less happy path.
        ClaimURLProtocol.responseBody = Data("{\"ok\":true,\"bookingId\":null}".utf8)

        let result = try await makeService().acceptClaim(token: "tok_1")

        #expect(result == .claimed(bookingId: nil))
    }

    @Test func acceptClaimMapsEveryDocumentedFailureToAnOutcome() async throws {
        // Every body verbatim from the live route. Note three distinct 409s and
        // two distinct 404s — proof the mapping cannot key on the status.
        #expect(
            try await outcome(
                status: 404,
                body: "{\"ok\":false,\"error\":\"Invite not found.\",\"code\":\"NOT_FOUND\"}"
            ) == .notFound
        )
        #expect(
            try await outcome(
                status: 410,
                body: "{\"ok\":false,\"error\":\"Invite is no longer available.\",\"code\":\"REVOKED\"}"
            ) == .revoked
        )
        #expect(
            try await outcome(
                status: 409,
                body: "{\"ok\":false,\"error\":\"Invite already claimed.\",\"code\":\"ALREADY_CLAIMED\"}"
            ) == .alreadyClaimed
        )
        #expect(
            try await outcome(
                status: 409,
                body: "{\"ok\":false,\"error\":\"Invite does not belong to this client.\",\"code\":\"CLIENT_MISMATCH\"}"
            ) == .clientMismatch
        )
        #expect(
            try await outcome(
                status: 404,
                body: "{\"ok\":false,\"error\":\"Client profile not found.\",\"code\":\"CLIENT_NOT_FOUND\"}"
            ) == .clientNotFound
        )
        #expect(
            try await outcome(
                status: 409,
                body: "{\"ok\":false,\"error\":\"Invite could not be claimed.\",\"code\":\"CONFLICT\"}"
            ) == .conflict
        )
        // A pro's bearer token reaching the client-only route.
        #expect(
            try await outcome(
                status: 403,
                body: "{\"ok\":false,\"error\":\"Forbidden\",\"code\":\"WORKSPACE_MISMATCH\",\"requiredWorkspace\":\"CLIENT\"}"
            ) == .notAClient
        )
    }

    @Test func acceptClaimThrowsOnAnUnknownCode() async throws {
        reset()
        ClaimURLProtocol.status = 500
        ClaimURLProtocol.responseBody = Data(
            "{\"ok\":false,\"error\":\"Internal server error\"}".utf8
        )

        do {
            _ = try await makeService().acceptClaim(token: "tok_1")
            Issue.record("expected acceptClaim to throw on an unmapped failure")
        } catch let error as APIError {
            // Unmapped failures must keep the server's own message rather than be
            // silently folded into a claim state that would be a lie.
            #expect(error.userMessage == "Internal server error")
        }
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
