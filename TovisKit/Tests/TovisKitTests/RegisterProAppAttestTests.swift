import Foundation
import Testing
@testable import TovisKit

// Proves registerPro sends the PRO branch's body: role=PRO, the profession +
// license state, the right `signupLocation` variant (PRO_MOBILE / PRO_SALON), and
// the App Attest attestation bound to its timestamp.
//
// Uses its OWN capture protocol (not the client suite's) so the two suites don't
// clobber each other's shared URLProtocol statics when run in parallel.

/// Intercepts requests and records the (streamed) body, replying 201 with a
/// canned register response. Distinct statics from the client suite's protocol.
final class ProCaptureBodyURLProtocol: URLProtocol {
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

@Suite(.serialized) struct RegisterProAppAttestTests {
    private static let proResponseJSON = Data("""
    {"ok":true,"user":{"id":"p1","email":"pro@example.com","role":"PRO"},
     "token":"jwt.a.b","nextUrl":null,"requiresPhoneVerification":true,
     "phoneVerificationSent":"true","phoneVerificationErrorCode":null,
     "requiresEmailVerification":true,"isPhoneVerified":false,
     "isEmailVerified":false,"isFullyVerified":false,"emailVerificationSent":"true",
     "needsManualLicenseUpload":false,"manualLicensePendingReview":false}
    """.utf8)

    private func makeAuth() -> (AuthService, RecordingAttestProvider) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProCaptureBodyURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let tokenStore = TokenStore(service: "me.tovis.app.session.tests.pro")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        let provider = RecordingAttestProvider(
            returning: AppAttestAttestation(keyId: "pro-key", attestationBase64: "YXR0ZXN0")
        )
        return (AuthService(api: api, tokenStore: tokenStore, appAttest: provider), provider)
    }

    @Test func mobileProSendsProMobileLocationAndRadius() async throws {
        ProCaptureBodyURLProtocol.capturedBody = nil
        ProCaptureBodyURLProtocol.responseBody = Self.proResponseJSON
        let (auth, provider) = makeAuth()

        _ = try await auth.registerPro(
            email: "pro@example.com",
            password: "secret",
            firstName: "Tori",
            lastName: "Morales",
            phone: "+15551234567",
            professionType: .barber,
            licenseState: "CA",
            businessName: "Fade Lab",
            handle: "fadelab",
            licenseNumber: "COS123",
            licenseExpiry: nil,
            location: .mobile(
                ClientSignupLocation(
                    postalCode: "92101",
                    city: "San Diego",
                    state: "CA",
                    countryCode: "US",
                    lat: 32.7,
                    lng: -117.1,
                    timeZoneId: "America/Los_Angeles"
                ),
                radiusMiles: 15
            ),
            deviceId: "device-pro"
        )

        let body = try #require(ProCaptureBodyURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["role"] as? String == "PRO")
        #expect(json["professionType"] as? String == "BARBER")
        #expect(json["licenseState"] as? String == "CA")
        #expect(json["businessName"] as? String == "Fade Lab")
        #expect(json["handle"] as? String == "fadelab")
        #expect(json["licenseNumber"] as? String == "COS123")
        #expect((json["mobileRadiusMiles"] as? NSNumber)?.intValue == 15)
        #expect(json["licenseExpiry"] == nil)

        let loc = try #require(json["signupLocation"] as? [String: Any])
        #expect(loc["kind"] as? String == "PRO_MOBILE")
        #expect(loc["postalCode"] as? String == "92101")
        #expect(loc["placeId"] == nil)

        // Attestation bound to the timestamp that was sent.
        let att = try #require(json["appAttest"] as? [String: Any])
        let timestamp = try #require((att["timestamp"] as? NSNumber)?.int64Value)
        let expected = AppAttestClientData.hash(
            email: "pro@example.com",
            phone: "+15551234567",
            timestampMs: timestamp
        )
        #expect(await provider.capturedHash == expected)
    }

    @Test func salonProSendsProSalonLocation() async throws {
        ProCaptureBodyURLProtocol.capturedBody = nil
        ProCaptureBodyURLProtocol.responseBody = Self.proResponseJSON
        let (auth, _) = makeAuth()

        _ = try await auth.registerPro(
            email: "salon@example.com",
            password: "secret",
            firstName: "Amara",
            lastName: "Stone",
            phone: "+15559876543",
            professionType: .cosmetologist,
            licenseState: "NY",
            businessName: nil,
            handle: nil,
            licenseNumber: "NY9988",
            licenseExpiry: "2027-01-31",
            location: .salon(
                ProSalonLocation(
                    placeId: "place-xyz",
                    formattedAddress: "123 Main St, New York, NY 10001",
                    city: "New York",
                    state: "NY",
                    postalCode: "10001",
                    countryCode: "US",
                    lat: 40.7,
                    lng: -74.0,
                    timeZoneId: "America/New_York"
                )
            ),
            deviceId: "device-salon"
        )

        let body = try #require(ProCaptureBodyURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["role"] as? String == "PRO")
        #expect(json["professionType"] as? String == "COSMETOLOGIST")
        #expect(json["licenseState"] as? String == "NY")
        #expect(json["licenseExpiry"] as? String == "2027-01-31")
        // Optional fields omitted (not sent as null).
        #expect(json["businessName"] == nil)
        #expect(json["handle"] == nil)
        #expect(json["mobileRadiusMiles"] == nil)

        let loc = try #require(json["signupLocation"] as? [String: Any])
        #expect(loc["kind"] as? String == "PRO_SALON")
        #expect(loc["placeId"] as? String == "place-xyz")
        #expect(loc["formattedAddress"] as? String == "123 Main St, New York, NY 10001")
    }
}
