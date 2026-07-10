import Foundation

/// Deterministic client idempotency keys — the native mirror of the web
/// `buildClientIdempotencyKey` (tovis-app `lib/idempotency/client.ts`), so both
/// clients dedupe mutating requests the same way.
///
/// The server contract is **"same key ⇒ same body"**: a request that reuses a
/// key with a *different* body is rejected (409 `IDEMPOTENCY_KEY_CONFLICT`), and
/// a request that mints a fresh key on every tap gets no dedup at all (a
/// double-tap can double-book / double-charge). Deriving the key from the call's
/// stable, distinguishing inputs threads that needle automatically:
///
/// - Two taps of the *same* action within one 60s bucket → identical key → the
///   server replays the first response instead of running the side effect twice.
/// - A genuinely different submission (edited amount, new content, different
///   flag) has a different `nonce` → a different key → it can neither be dropped
///   as a duplicate nor collide with the earlier body.
/// - A legitimate retry after the bucket window (default 60s) rolls to a new
///   bucket → a fresh key → allowed through.
///
/// Prefer deriving `nonce` from the request's *exact serialized body* (see
/// `idempotencyNonce(_:)`) so no volatile-yet-distinguishing field is ever
/// missed — a missed field would resurface the 409 conflict.
public func buildClientIdempotencyKey(
    scope: String,
    entityId: String,
    action: String = "",
    bucketMs: Double = 60_000,
    nonce: String = ""
) -> String {
    let scope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
    let entityId = entityId.trimmingCharacters(in: .whitespacesAndNewlines)
    let action = action.trimmingCharacters(in: .whitespacesAndNewlines)
    let nonce = nonce.trimmingCharacters(in: .whitespacesAndNewlines)

    // Match the web helper's invariant: a scope + entity must be present so keys
    // are always namespaced to a concrete target. Fall back to a random key
    // rather than trap — a unique key is always safe (it just skips dedup).
    guard !scope.isEmpty, !entityId.isEmpty else { return UUID().uuidString }

    let ms = bucketMs > 0 ? bucketMs : 60_000
    let bucket = Int((Date().timeIntervalSince1970 * 1000) / ms)

    let fingerprint = djb2Hash([scope, entityId, action, String(bucket), nonce].joined(separator: "\u{241F}"))

    return [scope, entityId, action.isEmpty ? "default" : action, String(bucket), fingerprint]
        .map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0 }
        .joined(separator: ":")
}

/// A stable nonce from an already-encoded request body — pass the same `Data`
/// you send as the POST body, encoded through `JSONEncoder.canonical`. That
/// encoder's `.sortedKeys` gives byte-stable output for a given `Encodable`, so
/// identical submissions hash identically while any field change shifts the
/// nonce. A bare `JSONEncoder()` does **not** guarantee stable key order, so a
/// nonce derived from its bytes could differ between two identical taps and
/// defeat dedup — always encode the body with `JSONEncoder.canonical`.
public func idempotencyNonce(_ body: Data) -> String {
    String(decoding: body, as: UTF8.self)
}

/// djb2, matching the web helper (32-bit wrapping, base-36 output). Internal
/// consistency is all that matters — iOS and web never share an in-flight key.
private func djb2Hash(_ input: String) -> String {
    var hash: UInt32 = 5381
    for unit in input.utf16 {
        hash = ((hash &<< 5) &+ hash) ^ UInt32(unit)
    }
    return String(hash, radix: 36)
}
