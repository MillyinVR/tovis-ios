import Foundation
import Testing
@testable import TovisKit

// Proves AuthService's post-signup EMAIL-verification helpers:
//  • verificationStatus() GETs /auth/verification/status on the authenticated
//    session and, crucially, persists the healed ACTIVE token the backend hands
//    back so the app's next request carries a verified bearer (native has no
//    cookie jar — this body token is the only channel).
//  • verificationStatus() leaves the stored token untouched while still pending
//    (token: null).
//  • sendEmailVerification() POSTs /auth/email/send on the authenticated session.

/// Captures the outgoing request (method, path, auth header, body) and replies
/// with a configurable status + body.
final class EmailVerificationURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedAuthHeader: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedMethod = request.httpMethod
        Self.capturedPath = request.url?.path
        Self.capturedAuthHeader = request.value(forHTTPHeaderField: "Authorization")
        Self.capturedBody = Self.readBody(request)

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

    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

@Suite(.serialized) struct EmailVerificationTests {
    private static let service = "me.tovis.app.session.emailverify.tests"

    private func makeStore() -> TokenStore { TokenStore(service: Self.service) }

    private func makeAuth(tokenStore: TokenStore) -> AuthService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmailVerificationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return AuthService(api: api, tokenStore: tokenStore)
    }

    private func reset() {
        EmailVerificationURLProtocol.capturedMethod = nil
        EmailVerificationURLProtocol.capturedPath = nil
        EmailVerificationURLProtocol.capturedAuthHeader = nil
        EmailVerificationURLProtocol.capturedBody = nil
        EmailVerificationURLProtocol.status = 200
        EmailVerificationURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    @Test func statusPersistsHealedActiveToken() async throws {
        reset()
        let store = makeStore()
        await store.save("verification.token") // the stale VERIFICATION bearer
        EmailVerificationURLProtocol.responseBody = Data("""
        {
          "ok": true,
          "user": { "id": "user_1", "email": "person@example.com", "phone": "+15551234567", "role": "CLIENT" },
          "sessionKind": "ACTIVE",
          "isPhoneVerified": true,
          "isEmailVerified": true,
          "isFullyVerified": true,
          "requiresPhoneVerification": false,
          "requiresEmailVerification": false,
          "nextUrl": "/looks",
          "token": "healed.active.token"
        }
        """.utf8)

        let result = try await makeAuth(tokenStore: store).verificationStatus()

        #expect(EmailVerificationURLProtocol.capturedMethod == "GET")
        #expect(EmailVerificationURLProtocol.capturedPath == "/api/v1/auth/verification/status")
        // Sent on the authenticated (verification) session.
        #expect(EmailVerificationURLProtocol.capturedAuthHeader == "Bearer verification.token")

        #expect(result.isFullyVerified)
        #expect(result.sessionKind == "ACTIVE")
        #expect(result.token == "healed.active.token")
        #expect(result.user.email == "person@example.com")

        // The healed ACTIVE token replaced the stored bearer.
        let stored = await store.token()
        #expect(stored == "healed.active.token")

        await store.clear()
    }

    @Test func statusKeepsStoredTokenWhileStillPending() async throws {
        reset()
        let store = makeStore()
        await store.save("verification.token")
        EmailVerificationURLProtocol.responseBody = Data("""
        {
          "ok": true,
          "user": { "id": "user_1", "email": "person@example.com", "phone": "+15551234567", "role": "CLIENT" },
          "sessionKind": "VERIFICATION",
          "isPhoneVerified": true,
          "isEmailVerified": false,
          "isFullyVerified": false,
          "requiresPhoneVerification": false,
          "requiresEmailVerification": true,
          "nextUrl": null,
          "token": null
        }
        """.utf8)

        let result = try await makeAuth(tokenStore: store).verificationStatus()

        #expect(result.token == nil)
        #expect(result.isFullyVerified == false)
        #expect(result.requiresEmailVerification)

        // No token in the body → the stored VERIFICATION bearer is untouched.
        let stored = await store.token()
        #expect(stored == "verification.token")

        await store.clear()
    }

    @Test func sendPostsToEmailSendAuthenticated() async throws {
        reset()
        let store = makeStore()
        await store.save("verification.token")
        EmailVerificationURLProtocol.responseBody = Data("""
        {
          "ok": true,
          "sent": true,
          "isPhoneVerified": true,
          "isEmailVerified": false,
          "isFullyVerified": false,
          "nextUrl": null
        }
        """.utf8)

        let result = try await makeAuth(tokenStore: store).sendEmailVerification()

        #expect(EmailVerificationURLProtocol.capturedMethod == "POST")
        #expect(EmailVerificationURLProtocol.capturedPath == "/api/v1/auth/email/send")
        #expect(EmailVerificationURLProtocol.capturedAuthHeader == "Bearer verification.token")
        #expect(result.sent == true)
        #expect(result.isEmailVerified == false)

        await store.clear()
    }
}
