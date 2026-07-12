import Foundation
import Testing
@testable import TovisKit

// Proves AuthService.googleLogin posts Google's id-token to /auth/google with the
// stable deviceId (unauthenticated, native-marked), persists the returned session
// token, and surfaces the backend's user-facing message when Google can't take
// over an existing account. Mirrors the server contract in
// app/api/v1/auth/google/route.ts (which reads only identityToken + deviceId).

/// Records the outgoing request and replies with a configurable status + body.
final class GoogleLoginURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var capturedAuthHeader: String?
    nonisolated(unsafe) static var capturedNativeHeader: String?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data()

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

@Suite(.serialized) struct GoogleLoginTests {
    private let tokenService = "me.tovis.app.session.google.tests"

    private func makeAuth() -> (AuthService, TokenStore) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleLoginURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: tokenService)
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return (AuthService(api: api, tokenStore: tokenStore), tokenStore)
    }

    private func resetProtocol() {
        GoogleLoginURLProtocol.capturedPath = nil
        GoogleLoginURLProtocol.capturedBody = nil
        GoogleLoginURLProtocol.capturedAuthHeader = nil
        GoogleLoginURLProtocol.capturedNativeHeader = nil
        GoogleLoginURLProtocol.status = 200
        GoogleLoginURLProtocol.responseBody = Data()
    }

    @Test func postsIdentityTokenAndPersistsSession() async throws {
        resetProtocol()
        GoogleLoginURLProtocol.responseBody = Data("""
        {
          "user": { "id": "u_1", "email": "person@example.com", "role": "CLIENT" },
          "token": "tok.google.session",
          "nextUrl": null,
          "isPhoneVerified": false,
          "isEmailVerified": true,
          "isFullyVerified": false
        }
        """.utf8)

        let (auth, tokenStore) = makeAuth()
        await tokenStore.clear()

        let response = try await auth.googleLogin(
            identityToken: "google.id.token",
            deviceId: "device-123"
        )

        #expect(GoogleLoginURLProtocol.capturedPath == "/api/v1/auth/google")
        // Pre-auth flow: no bearer attached, but still marked native.
        #expect(GoogleLoginURLProtocol.capturedAuthHeader == nil)
        #expect(GoogleLoginURLProtocol.capturedNativeHeader == "ios")

        let body = try #require(GoogleLoginURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["identityToken"] as? String == "google.id.token")
        #expect(json["deviceId"] as? String == "device-123")
        // Unlike Apple, no name fields are sent — the server reads them off the token.
        #expect(json["firstName"] == nil)
        #expect(json["lastName"] == nil)

        #expect(response.isEmailVerified == true)
        #expect(response.isFullyVerified == false)
        // The returned session token is persisted for the authenticated calls that follow.
        #expect(await tokenStore.token() == "tok.google.session")
    }

    @Test func surfacesBackendMessageWhenAccountConflicts() async throws {
        resetProtocol()
        GoogleLoginURLProtocol.status = 409
        GoogleLoginURLProtocol.responseBody = Data(
            "{\"error\":\"An account already exists for this email. Please sign in with your email and password.\",\"code\":\"ACCOUNT_EXISTS_UNVERIFIED\"}".utf8
        )

        let (auth, _) = makeAuth()

        await #expect {
            try await auth.googleLogin(identityToken: "google.id.token", deviceId: "device-123")
        } throws: { error in
            guard case let APIError.server(status, message, code) = error else { return false }
            return status == 409
                && message == "An account already exists for this email. Please sign in with your email and password."
                && code == "ACCOUNT_EXISTS_UNVERIFIED"
        }
    }
}
