import Testing
@testable import TovisKit

/// The idempotency-key contract: "same key ⇒ same body". These lock in that a
/// double-tap of the same action dedupes (same key) while any body change or
/// different target produces a distinct key — so neither the 409 conflict nor a
/// silent double-submit can recur. A large `bucketMs` pins both calls to one time
/// bucket so the determinism checks can't straddle a bucket boundary.
@Suite struct IdempotencyKeyTests {
    private let bucketMs: Double = 10_000_000  // ~2.7h — same bucket for the test run

    @Test func sameInputsProduceSameKey() {
        let a = buildClientIdempotencyKey(
            scope: "booking", entityId: "bk_1", action: "refund",
            bucketMs: bucketMs, nonce: "{\"amountCents\":5000}")
        let b = buildClientIdempotencyKey(
            scope: "booking", entityId: "bk_1", action: "refund",
            bucketMs: bucketMs, nonce: "{\"amountCents\":5000}")
        #expect(a == b)
    }

    @Test func changedBodyProducesDifferentKey() {
        let full = buildClientIdempotencyKey(
            scope: "booking", entityId: "bk_1", action: "refund",
            bucketMs: bucketMs, nonce: "{\"amountCents\":5000}")
        let partial = buildClientIdempotencyKey(
            scope: "booking", entityId: "bk_1", action: "refund",
            bucketMs: bucketMs, nonce: "{\"amountCents\":2500}")
        #expect(full != partial)
    }

    @Test func differentEntityOrActionProducesDifferentKey() {
        let base = buildClientIdempotencyKey(
            scope: "pro-booking", entityId: "bk_1", action: "cancel", bucketMs: bucketMs)
        let otherEntity = buildClientIdempotencyKey(
            scope: "pro-booking", entityId: "bk_2", action: "cancel", bucketMs: bucketMs)
        let otherAction = buildClientIdempotencyKey(
            scope: "pro-booking", entityId: "bk_1", action: "accept", bucketMs: bucketMs)
        #expect(base != otherEntity)
        #expect(base != otherAction)
    }

    @Test func keyIsNamespacedAndHeaderSafe() {
        let key = buildClientIdempotencyKey(
            scope: "pro-booking", entityId: "bk_1", action: "cancel", bucketMs: bucketMs)
        // scope:entity:action:bucket:fingerprint — five colon-separated segments,
        // all ASCII (safe as an HTTP header value).
        #expect(key.split(separator: ":").count == 5)
        #expect(key.allSatisfy { $0.isASCII })
    }

    @Test func missingScopeOrEntityFallsBackToUniqueKey() {
        // A blank namespace can't be deduped safely — fall back to a unique key
        // (always correct; just skips dedup) rather than collide across targets.
        let a = buildClientIdempotencyKey(scope: "", entityId: "bk_1", action: "cancel")
        let b = buildClientIdempotencyKey(scope: "", entityId: "bk_1", action: "cancel")
        #expect(a != b)
    }
}
