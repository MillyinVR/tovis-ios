import Foundation

public extension JSONEncoder {
    /// The single request-body encoder every TovisKit service routes through.
    ///
    /// `.sortedKeys` forces a deterministic, alphabetical key order. A bare
    /// `JSONEncoder` does **not** guarantee stable key order for a multi-field
    /// `Encodable` — the order can differ from one `encode` call to the next even
    /// within a single process run. That is invisible on the wire (JSON object key
    /// order is irrelevant to the server), but it silently breaks any idempotency
    /// key whose `nonce` is derived from the serialized body (see
    /// `idempotencyNonce(_:)`): a legit double-tap would encode to *different*
    /// bytes → a different nonce → a fresh key → no dedup, risking a double-submit
    /// (double-book / double-charge).
    ///
    /// Encoding **both** the wire body and its nonce through this one encoder keeps
    /// them byte-identical and stable across taps by construction, so no call site
    /// has to remember to sort keys. Sorted keys are safe on the wire, so there is
    /// never a reason to reach for a bare `JSONEncoder()` for a request body.
    ///
    /// A fresh instance is returned per access (matching prior per-call behavior)
    /// so the encoder is never shared across concurrent `encode` calls.
    static var canonical: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
