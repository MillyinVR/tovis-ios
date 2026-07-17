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
}
