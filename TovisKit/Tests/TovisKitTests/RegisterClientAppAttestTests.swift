import Foundation
import Testing
@testable import TovisKit

// Captures the outgoing /auth/register request to prove registerClient attaches
// the attestation AND binds its client-data hash to the timestamp it sends.

/// Records the client-data hash it was asked to attest over, and returns a
/// canned attestation (as a real device would).
actor RecordingAttestProvider: AppAttestProviding {
    private var stored: Data?
    private let attestation: AppAttestAttestation?

    init(returning attestation: AppAttestAttestation?) {
        self.attestation = attestation
    }

    var capturedHash: Data? { stored }

    func attest(clientDataHash: Data) async -> AppAttestAttestation? {
        stored = clientDataHash
        return attestation
    }
}

/// Intercepts requests and records the (streamed) body, replying 201 with a
/// canned register response.
final class CaptureBodyURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var responseBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedBody = Self.readBody(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 201,
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

@Suite(.serialized) struct RegisterClientAppAttestTests {
    private static let registerResponseJSON = Data("""
    {"ok":true,"user":{"id":"u1","email":"client@example.com","role":"CLIENT"},
     "token":"jwt.a.b","nextUrl":null,"requiresPhoneVerification":true,
     "requiresEmailVerification":true,"isPhoneVerified":false,
     "isEmailVerified":false,"isFullyVerified":false}
    """.utf8)

    @Test func sendsAttestationBoundToTheTimestamp() async throws {
        CaptureBodyURLProtocol.capturedBody = nil
        CaptureBodyURLProtocol.responseBody = Self.registerResponseJSON

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptureBodyURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let tokenStore = TokenStore(service: "me.tovis.app.session.tests")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        let provider = RecordingAttestProvider(
            returning: AppAttestAttestation(keyId: "key-xyz", attestationBase64: "YXR0ZXN0")
        )
        let auth = AuthService(api: api, tokenStore: tokenStore, appAttest: provider)

        _ = try await auth.registerClient(
            email: "client@example.com",
            password: "secret",
            firstName: "Tori",
            lastName: "Morales",
            phone: "+15551234567",
            location: ClientSignupLocation(
                postalCode: "90210",
                city: "Beverly Hills",
                state: "CA",
                countryCode: "US",
                lat: 34.0,
                lng: -118.0,
                timeZoneId: "America/Los_Angeles"
            ),
            deviceId: "device-1"
        )

        let body = try #require(CaptureBodyURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let att = try #require(json["appAttest"] as? [String: Any])
        #expect(att["keyId"] as? String == "key-xyz")
        #expect(att["attestation"] as? String == "YXR0ZXN0")

        let timestamp = try #require((att["timestamp"] as? NSNumber)?.int64Value)
        // The hash the provider attested over must be bound to the SAME timestamp
        // that was sent — that's what lets the backend recompute and verify it.
        let expected = AppAttestClientData.hash(
            email: "client@example.com",
            phone: "+15551234567",
            timestampMs: timestamp
        )
        let captured = await provider.capturedHash
        #expect(captured == expected)
    }
}
