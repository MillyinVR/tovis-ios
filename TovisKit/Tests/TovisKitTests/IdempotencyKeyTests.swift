import Foundation
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

    // MARK: - The bucket is a clock, and assertions must not race it

    /// The instant the real CI failure's key was minted (tovis-ios #242): its
    /// bucket segment was `29756502`, and the assertion that compared against it
    /// ran at 05:43:00.07Z — 70ms into the next bucket. Long past, so the
    /// live-clock comparison below can never coincidentally agree with it again.
    private let sentAt = Date(timeIntervalSince1970: 1_785_390_120)  // 2026-07-30T05:42:00Z

    @Test func bucketSegmentIsTheWallClockMinute() {
        // Confirms the diagnosis in code, not just in a commit message: a 60s
        // bucket is floor(epoch_ms / 60_000), so 05:42:00Z really is 29756502.
        let key = buildClientIdempotencyKey(
            scope: "s", entityId: "e", action: "a", now: sentAt)
        #expect(idempotencyKeyBucket(of: key) == 29_756_502)
    }

    @Test func pinnedRebuildReproducesAKeyMintedInAnotherBucket() {
        // A key sent at 05:42:00Z — the same relationship a captured header has to
        // an assertion running after the minute rolled over.
        let sent = buildClientIdempotencyKey(
            scope: "client-consultation-decision", entityId: "bk_1",
            action: "APPROVE", now: sentAt)

        // Pinning to the captured bucket reproduces it exactly, whenever this runs…
        #expect(rebuiltIdempotencyKey(
            matchingBucketOf: sent,
            scope: "client-consultation-decision", entityId: "bk_1",
            action: "APPROVE") == sent)

        // …whereas rebuilding against the LIVE clock — what these tests used to do
        // — does not. That gap IS the flake, and it is only ever visible when the
        // boundary falls between the send and the assertion. This is the control:
        // without it, the test above could pass for the wrong reason.
        #expect(buildClientIdempotencyKey(
            scope: "client-consultation-decision", entityId: "bk_1",
            action: "APPROVE") != sent)

        // A wrong action still fails the pinned compare — pinning removes the
        // clock from the comparison, not the wiring.
        #expect(rebuiltIdempotencyKey(
            matchingBucketOf: sent,
            scope: "client-consultation-decision", entityId: "bk_1",
            action: "REJECT") != sent)

        // A malformed header is a failure, never a silent match.
        #expect(rebuiltIdempotencyKey(
            matchingBucketOf: "not-a-key", scope: "s", entityId: "e") == nil)
    }

    @Test func bucketFreshnessToleratesExactlyOneRollover() {
        // Pinning gives up "is the bucket NOW?"; this is what covers it. One bucket
        // back must pass — a send moments before a boundary is correct — while two
        // back is stale.
        //
        // Both the key and the check are pinned to the same `now`, and the offsets
        // are measured from the bucket's own start. Writing this the obvious way
        // (`Date() - 61`) crosses TWO boundaries whenever the current instant is
        // within a second of one, so it fails about 1 run in 60 — a second flake,
        // introduced while fixing the first. It failed that way once here before
        // this rewrite.
        let now = Date()
        let start = idempotencyBucketStart(containing: now)
        func key(at instant: Date) -> String {
            buildClientIdempotencyKey(scope: "s", entityId: "e", now: instant)
        }

        #expect(idempotencyKeyBucketIsCurrent(key(at: now), now: now))
        #expect(idempotencyKeyBucketIsCurrent(
            key(at: start.addingTimeInterval(-0.5)), now: now))          // one back
        #expect(idempotencyKeyBucketIsCurrent(
            key(at: start.addingTimeInterval(-60.5)), now: now) == false)  // two back
        #expect(idempotencyKeyBucketIsCurrent(key(at: sentAt), now: now) == false)
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

    // A multi-field `Encodable` whose properties are declared OUT of alphabetical
    // order — the exact shape a bare `JSONEncoder` can serialize with unstable key
    // order. Single-field bodies never regressed (nothing to reorder), so the
    // regression must exercise a body with 2+ keys.
    private struct MultiFieldBody: Encodable {
        let zeta: String
        let alpha: Int
        let mid: Bool
    }

    @Test func canonicalEncoderSortsKeysDeterministically() {
        // The fix's core guarantee: `.sortedKeys` emits keys alphabetically
        // regardless of declaration order, so the bytes are stable by construction.
        let json = String(
            decoding: try! JSONEncoder.canonical.encode(
                MultiFieldBody(zeta: "z", alpha: 1, mid: true)),
            as: UTF8.self)
        let iAlpha = json.range(of: "alpha")!.lowerBound
        let iMid = json.range(of: "mid")!.lowerBound
        let iZeta = json.range(of: "zeta")!.lowerBound
        #expect(iAlpha < iMid)
        #expect(iMid < iZeta)
    }

    @Test func multiFieldBodyYieldsStableNonceAndKeyAcrossEncodes() throws {
        // A legit double-tap re-encodes the SAME body: canonical encoding must
        // produce identical bytes → identical nonce → identical key, so the server
        // replays instead of double-submitting. Encode twice to prove stability.
        let body = MultiFieldBody(zeta: "z", alpha: 1, mid: true)
        let first = idempotencyNonce(try JSONEncoder.canonical.encode(body))
        let second = idempotencyNonce(try JSONEncoder.canonical.encode(body))
        #expect(first == second)

        let keyA = buildClientIdempotencyKey(
            scope: "client-checkout-products", entityId: "bk_1",
            action: "save-selection", bucketMs: bucketMs, nonce: first)
        let keyB = buildClientIdempotencyKey(
            scope: "client-checkout-products", entityId: "bk_1",
            action: "save-selection", bucketMs: bucketMs, nonce: second)
        #expect(keyA == keyB)

        // A changed field must still shift the nonce (dedup only replays true
        // duplicates, never a genuinely different submission).
        let changed = idempotencyNonce(
            try JSONEncoder.canonical.encode(MultiFieldBody(zeta: "z", alpha: 2, mid: true)))
        #expect(changed != first)
    }
}
