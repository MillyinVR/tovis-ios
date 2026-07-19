import Foundation
import Testing
@testable import TovisKit

// Characterization tests for the compact-count formatter extracted verbatim from
// `LooksView`'s private `countLabel`/`followerLabel`. Written against the old
// inline behavior so the extraction is provably a move, not a rewrite.

@Suite("Compact count")
struct CompactCountTests {
    @Test("Below a thousand is exact")
    func exactBelowThousand() {
        #expect(CompactCount.label(0) == "0")
        #expect(CompactCount.label(1) == "1")
        #expect(CompactCount.label(999) == "999")
    }

    @Test("A whole thousand drops the decimal")
    func wholeThousands() {
        #expect(CompactCount.label(1000) == "1K")
        #expect(CompactCount.label(12000) == "12K")
        #expect(CompactCount.label(100_000) == "100K")
    }

    @Test("A partial thousand keeps one decimal")
    func partialThousands() {
        #expect(CompactCount.label(1200) == "1.2K")
        #expect(CompactCount.label(1234) == "1.2K")
        #expect(CompactCount.label(99_900) == "99.9K")
    }

    @Test("Followers pluralize, then compact")
    func followers() {
        #expect(CompactCount.followers(0) == "0 followers")
        #expect(CompactCount.followers(1) == "1 follower")
        #expect(CompactCount.followers(2) == "2 followers")
        #expect(CompactCount.followers(999) == "999 followers")
        #expect(CompactCount.followers(1000) == "1K followers")
        #expect(CompactCount.followers(1200) == "1.2K followers")
    }

    // MARK: - Rollover past a million (round-3 queue item 15)

    // Everything above this line characterizes the ORIGINAL K-only formatter and
    // must keep passing — the rollover fix changes nothing below 1M. Everything
    // below fails against that formatter, which is the point: it had no M branch,
    // so a viral look read "1000K" forever.

    @Test("Rolls over to M instead of reporting a four-digit K")
    func millions() {
        // The bug: `1000K` / `1000.0K`. Web's `formatCompactCount` fixed the
        // identical pair in #680 — these expectations are lifted from
        // `lib/format/compactCount.test.ts` so the platforms cannot drift again.
        #expect(CompactCount.label(999_999) == "1M")
        #expect(CompactCount.label(1_000_000) == "1M")
        #expect(CompactCount.label(1_200_000) == "1.2M")
        #expect(CompactCount.label(12_345_678) == "12.3M")
    }

    @Test("Keeps going above a million")
    func billions() {
        #expect(CompactCount.label(1_000_000_000) == "1B")
        #expect(CompactCount.label(2_500_000_000) == "2.5B")
        #expect(CompactCount.label(1_000_000_000_000) == "1T")
    }

    @Test("Rounds to one fraction digit rather than truncating the unit")
    func roundingToOneDigit() {
        // 9,999 rounds UP across the unit boundary (9.999K -> 10K), which is
        // where a naive floor would render "9.9K".
        #expect(CompactCount.label(9_999) == "10K")
        #expect(CompactCount.label(10_500) == "10.5K")
        #expect(CompactCount.label(100_500) == "100.5K")
    }

    @Test("A negative count normalizes to zero rather than rendering a sign")
    func negativesClamp() {
        // `FollowToggle` clamps at zero, but a stale server count can still
        // arrive negative; web normalizes with Math.max(0, …) and so do we.
        #expect(CompactCount.label(-1) == "0")
        #expect(CompactCount.label(-5_000) == "0")
        #expect(CompactCount.followers(-1) == "0 followers")
    }

    // MARK: - The pro Looks-performance formatter folded in

    // `ProLooksPerformanceView` carried its own private `compact(_:)`. It is
    // deleted in favour of `CompactCount.label`; these pin the three ways it
    // differed, transcribed from the implementation being replaced:
    //
    //     private static func compact(_ n: Int) -> String {
    //         if n < 1000 { return "\(n)" }
    //         let k = Double(n) / 1000
    //         return String(format: k < 10 ? "%.1fk" : "%.0fk", k)
    //     }
    //
    // (1) lowercase "k"; (2) a whole thousand kept its ".0"; (3) at or above
    // 10,000 it rounded the fraction AWAY entirely. Tori's call was to fold it
    // in, so all three change — toward the canonical rule.
    @Test("The pro performance screen now renders the canonical labels")
    func proPerformanceFolding() {
        #expect(CompactCount.label(1_234) == "1.2K")   // was "1.2k"
        #expect(CompactCount.label(1_000) == "1K")     // was "1.0k"
        #expect(CompactCount.label(12_500) == "12.5K") // was "12k"
        #expect(CompactCount.label(45_000) == "45K")   // was "45k"
        #expect(CompactCount.label(1_000_000) == "1M") // was "1000k"
    }
}
