import Foundation
import CryptoKit

#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// An App Attest attestation the native app produces so it can register without
/// solving a Turnstile captcha (which native can't render). The backend verifies
/// this against Apple's App Attest Root CA — see lib/auth/appAttest.ts.
public struct AppAttestAttestation: Sendable {
    /// Apple's key id (base64 SHA256 of the attested public key).
    public let keyId: String
    /// base64 CBOR attestation object.
    public let attestationBase64: String
}

/// Produces an App Attest attestation over a caller-supplied client-data hash.
/// Abstracted so signup is testable off-device (the Simulator and the macOS test
/// host can't attest).
public protocol AppAttestProviding: Sendable {
    /// Attest over `clientDataHash`, or return nil when App Attest is unavailable
    /// (Simulator, unsupported device, or the OS declined). A nil result means the
    /// request goes out without an attestation — the server accepts that only via
    /// its local dev fail-open, and rejects it on a real deployment.
    func attest(clientDataHash: Data) async -> AppAttestAttestation?
}

/// The client data the attestation is bound to. MUST match the backend's
/// `computeRegistrationClientDataHash`: SHA256("<email>\n<phone>\n<timestampMs>"),
/// hashing the SAME raw strings the request registers with so the attestation is
/// cryptographically tied to this identity.
public enum AppAttestClientData {
    public static func hash(email: String, phone: String, timestampMs: Int64) -> Data {
        let material = "\(email)\n\(phone)\n\(timestampMs)"
        return Data(SHA256.hash(data: Data(material.utf8)))
    }
}

/// Real provider backed by DeviceCheck App Attest. Generates a fresh Secure
/// Enclave key per signup and attests it. Returns nil whenever App Attest isn't
/// supported (e.g. the Simulator) so local signup degrades to the server's dev
/// fail-open and production simply fails closed.
public struct DeviceCheckAppAttestProvider: AppAttestProviding {
    public init() {}

    public func attest(clientDataHash: Data) async -> AppAttestAttestation? {
        #if canImport(DeviceCheck)
        let service = DCAppAttestService.shared
        guard service.isSupported else { return nil }
        do {
            let keyId = try await service.generateKey()
            let attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)
            return AppAttestAttestation(
                keyId: keyId,
                attestationBase64: attestation.base64EncodedString()
            )
        } catch {
            // A failure here (no network for Apple's attestation service, rate
            // limiting, etc.) shouldn't crash signup — fall through to no
            // attestation and let the server decide.
            return nil
        }
        #else
        return nil
        #endif
    }
}

/// A provider that never attests — the default off Apple devices (unit tests).
public struct UnsupportedAppAttestProvider: AppAttestProviding {
    public init() {}
    public func attest(clientDataHash: Data) async -> AppAttestAttestation? { nil }
}
