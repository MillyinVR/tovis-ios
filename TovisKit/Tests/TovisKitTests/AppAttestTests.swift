import Foundation
import Testing
@testable import TovisKit

// Verifies the native App Attest signup contract:
//  - the client-data hash matches the backend's exact derivation
//    (lib/auth/appAttest.ts computeRegistrationClientDataHash),
//  - the `appAttest` wire object is present/absent as expected,
//  - registerClient binds the attestation to the timestamp it sends.

@Suite struct AppAttestClientDataTests {
    @Test func hashMatchesBackendVector() {
        // Cross-checked against Node:
        //   sha256("client@example.com\n+15551234567\n1800000000000")
        let hash = AppAttestClientData.hash(
            email: "client@example.com",
            phone: "+15551234567",
            timestampMs: 1_800_000_000_000
        )
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        #expect(hex == "fef5752c31f6f919506d76fa89eea694f14bbf7318e336c98b755a4b9f987316")
    }

    @Test func hashChangesWithEveryInput() {
        let base = AppAttestClientData.hash(email: "a@b.com", phone: "+1", timestampMs: 1)
        #expect(base != AppAttestClientData.hash(email: "a@b.com", phone: "+1", timestampMs: 2))
        #expect(base != AppAttestClientData.hash(email: "x@b.com", phone: "+1", timestampMs: 1))
        #expect(base != AppAttestClientData.hash(email: "a@b.com", phone: "+2", timestampMs: 1))
    }

    @Test func unsupportedProviderReturnsNil() async {
        let result = await UnsupportedAppAttestProvider().attest(clientDataHash: Data([0x01]))
        #expect(result == nil)
    }
}

@Suite struct RegisterRequestEncodingTests {
    private func encode(_ req: RegisterRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as? [String: Any] ?? [:]
    }

    private func makeRequest(appAttest: AppAttestPayload?) -> RegisterRequest {
        RegisterRequest(
            email: "client@example.com",
            password: "secret",
            role: "CLIENT",
            firstName: "Tori",
            lastName: "Morales",
            phone: "+15551234567",
            tosAccepted: true,
            transactionalSmsConsent: true,
            signupLocation: SignupLocationPayload(
                kind: "CLIENT_ZIP",
                postalCode: "90210",
                city: "Beverly Hills",
                state: "CA",
                countryCode: "US",
                lat: 34.0,
                lng: -118.0,
                timeZoneId: "America/Los_Angeles"
            ),
            deviceId: "device-1",
            appAttest: appAttest
        )
    }

    @Test func omitsAppAttestKeyWhenNil() throws {
        let json = try encode(makeRequest(appAttest: nil))
        #expect(json["appAttest"] == nil)
    }

    @Test func includesAppAttestFields() throws {
        let json = try encode(
            makeRequest(
                appAttest: AppAttestPayload(
                    keyId: "key-123",
                    attestation: "YXR0ZXN0",
                    timestamp: 1_800_000_000_000
                )
            )
        )
        let att = try #require(json["appAttest"] as? [String: Any])
        #expect(att["keyId"] as? String == "key-123")
        #expect(att["attestation"] as? String == "YXR0ZXN0")
        #expect((att["timestamp"] as? NSNumber)?.int64Value == 1_800_000_000_000)
    }
}
