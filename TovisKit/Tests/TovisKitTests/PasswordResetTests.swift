import Foundation
import Testing
@testable import TovisKit

// Proves AuthService.requestPasswordReset / confirmPasswordReset hit the right
// endpoints with the right (unauthenticated) bodies, and that a rejected confirm
// surfaces the backend's user-facing message.

/// Records the outgoing request (path, streamed body, headers) and replies with a
/// configurable status + body so a single protocol drives both success and failure.
final class PasswordResetURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var capturedAuthHeader: String?
    nonisolated(unsafe) static var capturedNativeHeader: String?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedBody = Self.readBody(request)
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

@Suite(.serialized) struct PasswordResetTests {
    private func makeAuth() -> AuthService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PasswordResetURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.reset.tests")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return AuthService(api: api, tokenStore: tokenStore)
    }

    @Test func requestPostsEmailUnauthenticated() async throws {
        PasswordResetURLProtocol.capturedPath = nil
        PasswordResetURLProtocol.capturedBody = nil
        PasswordResetURLProtocol.capturedAuthHeader = nil
        PasswordResetURLProtocol.capturedNativeHeader = nil
        PasswordResetURLProtocol.status = 200
        PasswordResetURLProtocol.responseBody = Data("{\"ok\":true}".utf8)

        try await makeAuth().requestPasswordReset(email: "person@example.com")

        #expect(PasswordResetURLProtocol.capturedPath == "/api/v1/auth/password-reset/request")
        // No bearer token attached (this is a pre-auth flow)…
        #expect(PasswordResetURLProtocol.capturedAuthHeader == nil)
        // …but it is still marked as a native request.
        #expect(PasswordResetURLProtocol.capturedNativeHeader == "ios")

        let body = try #require(PasswordResetURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["email"] as? String == "person@example.com")
    }

    @Test func confirmPostsTokenAndPassword() async throws {
        PasswordResetURLProtocol.capturedPath = nil
        PasswordResetURLProtocol.capturedBody = nil
        PasswordResetURLProtocol.status = 200
        PasswordResetURLProtocol.responseBody = Data("{\"ok\":true}".utf8)

        try await makeAuth().confirmPasswordReset(token: "tok_1.secret", password: "brand-new-pass")

        #expect(PasswordResetURLProtocol.capturedPath == "/api/v1/auth/password-reset/confirm")

        let body = try #require(PasswordResetURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["token"] as? String == "tok_1.secret")
        #expect(json["password"] as? String == "brand-new-pass")
    }

    @Test func confirmSurfacesBackendMessageOnRejection() async throws {
        PasswordResetURLProtocol.status = 400
        PasswordResetURLProtocol.responseBody = Data(
            "{\"ok\":false,\"error\":\"This reset link is invalid or has expired.\",\"code\":\"INVALID_TOKEN\"}".utf8
        )

        await #expect {
            try await makeAuth().confirmPasswordReset(token: "bad", password: "brand-new-pass")
        } throws: { error in
            guard case let APIError.server(status, message, code) = error else { return false }
            return status == 400
                && message == "This reset link is invalid or has expired."
                && code == "INVALID_TOKEN"
        }
    }
}
