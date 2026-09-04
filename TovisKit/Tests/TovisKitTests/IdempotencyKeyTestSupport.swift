import Foundation
@testable import TovisKit

// Shared helpers for asserting the idempotency-key header a service actually sent.
//
// 🔴 Why these exist. `buildClientIdempotencyKey` derives one of the key's five
// segments from the wall clock — `Int(now_ms / bucketMs)`, a 60s bucket by
// default. So a test that captures a real request's header and then calls the
// builder again to compare is comparing two *clock readings* as much as two
// derivations: when the minute rolls over between the send and the assertion, the
// buckets differ, the fingerprints differ, and the test fails for a reason that
// has nothing to do with the code under test.
//
// That is not hypothetical. `ConsultationDecisionTests
// .approvePostsWithIdempotencyKeyAndAction` failed exactly that way in CI on
// tovis-ios #242 (an unrelated PR): the sent key carried bucket `29756502`
// — 05:42:00–05:43:00Z — and the assertion recomputed at **05:43:00.07Z**, 70ms
// into the next bucket. A re-run of the identical SHA passed. At ~2.5s per suite
// run that is roughly a 1-in-800 chance per run, which is frequent enough to read
// as somebody's bug and rare enough to be dismissed as noise — the worst kind.
//
// It recurred on 2026-09-04 in a SECOND shape this file did not spell out, and
// `main` went red on a PR that touched none of the code involved
// (`ProMoneyTrailWriteTests.refundNoShowFeeKeyIsStableAcrossRepeatTaps`, run
// 33832875367): a "the key is stable across repeat taps" test compared two LIVE
// captures to each other — `#expect(captured == firstKey)` — with no rebuild in
// sight. That is the same bug wearing different clothes. Two clock readings are
// two clock readings whether one of them came from the builder or from a second
// send; the sends were 0.15s apart and the 03:23:00Z boundary landed between
// them. Six call sites had this shape and are now all pinned.
//
// 🔴 So: NEVER compare one captured idempotency key to another captured one with
// `==`. Compare EACH capture to the derivation it should have produced, pinned to
// that capture's own bucket. Two keys that are each their own honest derivation
// of the same inputs are identical within a bucket — which is the invariant the
// test actually means. (An `!=` between two live captures cannot go falsely red,
// so those are left alone.)
//
// The fix is NOT to loosen the assertion. Read the bucket back off the captured
// key and pin the rebuild to it: scope, entity, action and the body fingerprint
// are all still compared byte for byte, and only the clock is taken out of the
// comparison. `idempotencyKeyBucketIsCurrent` then covers the one thing that
// pinning gives up — that the bucket really is *now* — with the rollover
// tolerance that assertion actually needs.

/// The key the client SHOULD have sent, rebuilt against the time bucket the
/// CAPTURED key used. Returns nil if `captured` isn't the 5-segment shape, so a
/// malformed header fails the test instead of silently matching.
///
/// Everything the client controls is still verified exactly: a wrong scope,
/// entity, action or body nonce all change the fingerprint and fail the compare.
func rebuiltIdempotencyKey(
    matchingBucketOf captured: String,
    scope: String,
    entityId: String,
    action: String = "",
    bucketMs: Double = 60_000,
    nonce: String = ""
) -> String? {
    guard let bucket = idempotencyKeyBucket(of: captured) else { return nil }

    // Any instant inside the bucket reproduces it; its start is the one we can
    // name exactly. (`bucket * bucketMs` is well under 2^53, so this is exact.)
    let bucketStart = Date(timeIntervalSince1970: bucket * bucketMs / 1000)

    return buildClientIdempotencyKey(
        scope: scope, entityId: entityId, action: action,
        bucketMs: bucketMs, nonce: nonce, now: bucketStart)
}

/// The bucket segment of a `scope:entity:action:bucket:fingerprint` key.
func idempotencyKeyBucket(of key: String) -> Double? {
    let segments = key.split(separator: ":", omittingEmptySubsequences: false)
    guard segments.count == 5 else { return nil }
    return Double(segments[3])
}

/// Whether a captured key's bucket is the CURRENT one — or the one just before
/// it, because a send moments before a boundary is correct and must not fail.
/// This is the rollover-tolerant half of the check: pinning the rebuild proves
/// the derivation, this proves the bucket is live rather than stale or absent.
///
/// - Parameter now: defaults to the current time. Pass it explicitly to test THIS
///   function — asserting on its tolerance with wall-clock arithmetic
///   (`Date() - 61`) is itself boundary-dependent, which is the very trap that
///   put this file here.
func idempotencyKeyBucketIsCurrent(
    _ key: String, bucketMs: Double = 60_000, now: Date = Date()
) -> Bool {
    guard let bucket = idempotencyKeyBucket(of: key) else { return false }
    let current = (now.timeIntervalSince1970 * 1000 / bucketMs).rounded(.down)
    return bucket == current || bucket == current - 1
}

/// The instant a bucket begins, for an instant inside it — so a test can name
/// "exactly one bucket back" instead of subtracting seconds and hoping.
func idempotencyBucketStart(containing instant: Date, bucketMs: Double = 60_000) -> Date {
    let bucket = (instant.timeIntervalSince1970 * 1000 / bucketMs).rounded(.down)
    return Date(timeIntervalSince1970: bucket * bucketMs / 1000)
}
