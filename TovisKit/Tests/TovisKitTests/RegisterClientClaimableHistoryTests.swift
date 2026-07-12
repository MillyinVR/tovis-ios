import Foundation
import Testing
@testable import TovisKit

// Proves the cold self-serve-claim 409 surfaces its `maskedDestination` hint.
//
// A normal client signup whose email/phone matches an existing UNCLAIMED profile
// gets a 409 `{ code: "CLAIMABLE_HISTORY", maskedDestination: "t***@x.com" }` (the
// backend mailed/texted a claim link to the on-file contact instead of creating a
// colliding account). registerClient opts into `captureErrorDetails`, so that
// masked hint must ride through on `APIError.serverDetails` rather than being
// dropped by the plain `.server` path.

/// Replies with a fixed status + JSON body so we can simulate the 409.
final class CannedResponseURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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
}

@Suite(.serialized) struct RegisterClientClaimableHistoryTests {
    private func makeAuth() -> AuthService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.tests")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return AuthService(api: api, tokenStore: tokenStore, appAttest: RecordingAttestProvider(returning: nil))
    }

    private func register(_ auth: AuthService) async throws -> RegisterResponse {
        try await auth.registerClient(
            email: "tori@example.com",
            password: "supersecret",
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
    }

    @Test func surfacesMaskedDestinationOnClaimableHistory() async throws {
        CannedResponseURLProtocol.status = 409
        CannedResponseURLProtocol.responseBody = Data("""
        {"ok":false,"error":"We found existing history for this contact.",
         "code":"CLAIMABLE_HISTORY","maskedDestination":"t***@example.com"}
        """.utf8)

        let auth = makeAuth()

        await #expect(throws: APIError.serverDetails(
            status: 409,
            message: "We found existing history for this contact.",
            code: "CLAIMABLE_HISTORY",
            maskedDestination: "t***@example.com"
        )) {
            _ = try await register(auth)
        }
    }

    @Test func toleratesClaimableHistoryWithoutAMask() async throws {
        // When neither channel could be masked the backend sends a null
        // maskedDestination; the code must still arrive on `.serverDetails`.
        CannedResponseURLProtocol.status = 409
        CannedResponseURLProtocol.responseBody = Data("""
        {"ok":false,"error":"We found existing history for this contact.",
         "code":"CLAIMABLE_HISTORY","maskedDestination":null}
        """.utf8)

        let auth = makeAuth()

        await #expect(throws: APIError.serverDetails(
            status: 409,
            message: "We found existing history for this contact.",
            code: "CLAIMABLE_HISTORY",
            maskedDestination: nil
        )) {
            _ = try await register(auth)
        }
    }
}
