import Foundation
import Testing
@testable import TovisKit

// Proves ProVerificationService hits the right endpoints as authenticated native
// requests and decodes the verification snapshot — including the makeup (non-
// licensed) arm and tolerating an unknown status string.

/// Serves a canned body and records the outgoing request.
final class ProVerificationURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedAuthHeader: String?
    nonisolated(unsafe) static var capturedNativeHeader: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)
    /// Extra response headers (e.g. a redirect `Location`), merged over the base.
    nonisolated(unsafe) static var responseHeaders: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedAuthHeader = request.value(forHTTPHeaderField: "Authorization")
        Self.capturedNativeHeader = request.value(forHTTPHeaderField: "x-tovis-native")
        // URLProtocol strips httpBody for some methods; read the stream too.
        if let body = request.httpBody {
            Self.capturedBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4096
            var buffer = [UInt8](repeating: 0, count: size)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.capturedBody = data
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"].merging(Self.responseHeaders) { _, new in new }
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct ProVerificationTests {
    private func makeService() async -> ProVerificationService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProVerificationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.verification.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        let media = ProMediaService(api: api, supabaseURL: nil, supabaseKey: nil)
        return ProVerificationService(api: api, media: media)
    }

    private func reset(_ body: String) {
        ProVerificationURLProtocol.capturedPath = nil
        ProVerificationURLProtocol.capturedMethod = nil
        ProVerificationURLProtocol.capturedAuthHeader = nil
        ProVerificationURLProtocol.capturedNativeHeader = nil
        ProVerificationURLProtocol.capturedBody = nil
        ProVerificationURLProtocol.status = 200
        ProVerificationURLProtocol.responseBody = Data(body.utf8)
        ProVerificationURLProtocol.responseHeaders = [:]
    }

    @Test func getsVerificationAsAuthenticatedNativeRequest() async throws {
        reset("""
        {"ok":true,"verification":{"status":"PENDING","licenseVerified":false,"isLicensed":true,\
        "license":{"state":"CA","number":"COS123456","expiry":"2027-03-15"},\
        "methods":[{"type":"LICENSE","title":"State license","description":"A clear photo."},\
        {"type":"ID_CARD","title":"Government ID","description":"A government-issued photo ID."}],\
        "docs":[{"id":"doc_1","type":"LICENSE","typeLabel":"State license","status":"PENDING",\
        "label":"State license (pro upload)","createdAt":"2026-07-01T12:00:00.000Z","adminNote":null}]}}
        """)

        let v = try await makeService().verification()

        #expect(ProVerificationURLProtocol.capturedPath == "/api/v1/pro/verification")
        #expect(ProVerificationURLProtocol.capturedMethod == "GET")
        #expect(ProVerificationURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(ProVerificationURLProtocol.capturedNativeHeader == "ios")

        #expect(v.status == .pending)
        #expect(v.isLicensed)
        #expect(v.licenseVerified == false)
        #expect(v.license.state == "CA")
        #expect(v.license.number == "COS123456")
        #expect(v.license.expiry == "2027-03-15")
        #expect(v.methods.map(\.type) == ["LICENSE", "ID_CARD"])
        #expect(v.docs.count == 1)
        #expect(v.docs.first?.status == .pending)
        #expect(v.docs.first?.typeLabel == "State license")
    }

    @Test func decodesNonLicensedMakeupArm() async throws {
        reset("""
        {"ok":true,"verification":{"status":"APPROVED","licenseVerified":false,"isLicensed":false,\
        "license":{"state":null,"number":null,"expiry":null},\
        "methods":[{"type":"MAKEUP_PRIMARY","title":"Makeup certificate","description":"Primary."},\
        {"type":"ID_CARD","title":"Government ID","description":"ID."}],"docs":[]}}
        """)

        let v = try await makeService().verification()

        #expect(v.status == .approved)
        #expect(v.isLicensed == false)
        #expect(v.license.state == nil)
        #expect(v.license.expiry == nil)
        #expect(v.methods.first?.type == "MAKEUP_PRIMARY")
        #expect(v.docs.isEmpty)
    }

    @Test func toleratesUnknownStatus() async throws {
        reset("""
        {"ok":true,"verification":{"status":"SOME_FUTURE_STATUS","licenseVerified":true,"isLicensed":true,\
        "license":{"state":"NY","number":"X","expiry":null},"methods":[],"docs":[]}}
        """)

        let v = try await makeService().verification()

        #expect(v.status == .unknown)
        #expect(v.status.label == "Unknown")
    }

    @Test func saveLicensePatchesLicenseEndpoint() async throws {
        reset("{\"ok\":true,\"license\":{}}")

        try await makeService().saveLicense(state: "CA", number: "COS999", expiry: "2028-01-01")

        #expect(ProVerificationURLProtocol.capturedPath == "/api/v1/pro/license")
        #expect(ProVerificationURLProtocol.capturedMethod == "PATCH")

        let body = try #require(ProVerificationURLProtocol.capturedBody)
        let decoded = try JSONDecoder().decode(LicenseBodyProbe.self, from: body)
        #expect(decoded.licenseState == "CA")
        #expect(decoded.licenseNumber == "COS999")
        #expect(decoded.licenseExpiry == "2028-01-01")
    }

    @Test func deleteDocumentHitsDeleteEndpoint() async throws {
        reset("{\"ok\":true}")

        try await makeService().deleteDocument(id: "doc_42")

        #expect(ProVerificationURLProtocol.capturedPath == "/api/v1/pro/verification-docs/doc_42")
        #expect(ProVerificationURLProtocol.capturedMethod == "DELETE")
    }

    @Test func documentPreviewResolvesSignedRedirectLocation() async throws {
        reset("")
        // The doc route authenticates then 302-redirects to a short-lived signed
        // URL; the native client reads the `Location` (not the image) and hands it
        // to AsyncImage. Prove the authenticated GET returns that signed URL.
        ProVerificationURLProtocol.status = 302
        ProVerificationURLProtocol.responseHeaders = [
            "Location": "https://signed.example/doc.jpg?token=abc",
        ]

        let url = try await makeService().documentPreviewURL(id: "doc_7")

        #expect(ProVerificationURLProtocol.capturedPath == "/api/v1/pro/verification-docs/doc_7")
        #expect(ProVerificationURLProtocol.capturedMethod == "GET")
        #expect(ProVerificationURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(url.absoluteString == "https://signed.example/doc.jpg?token=abc")
    }

    @Test func documentPreviewThrowsWhenNotARedirect() async throws {
        reset("{\"ok\":false,\"error\":\"Forbidden.\"}")
        // Someone else's doc / an unsupported pointer isn't a 3xx — the caller must
        // get a throw (→ "no preview"), never a bogus URL.
        ProVerificationURLProtocol.status = 403

        var threw = false
        do { _ = try await makeService().documentPreviewURL(id: "doc_x") } catch { threw = true }
        #expect(threw)
    }

    private struct LicenseBodyProbe: Decodable {
        let licenseState: String
        let licenseNumber: String
        let licenseExpiry: String
    }
}
