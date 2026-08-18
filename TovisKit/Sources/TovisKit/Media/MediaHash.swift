// The client-claimed sha256 of a captured photo's bytes — computed locally at
// capture (or retry) time so it can ride the upload alongside `capturedAt`,
// then compared against the server's own hash of the bytes it actually
// received (tovis-app's MediaCaptureAttestation). This is never trusted
// alone server-side: a match doesn't prove the photo is real, and a
// mismatch doesn't prove tampering — it's a claim, kept for comparison.
import CryptoKit
import Foundation

public enum MediaHash {
    /// Lowercase hex sha256, matching the server's
    /// `createHash('sha256').digest('hex')`.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
