import Foundation
import Testing
@testable import TovisKit

// The blank-token guard was re-implemented ~36 times across both targets under
// five different names, because the canonical helper was `internal` to TovisKit
// and the app target could not see it. Round-3 queue item 15 made it `public`
// and collapsed the copies.
//
// These tests exist for two reasons:
//
//  1. Pin the canonical contract, now that a great many call sites depend on it.
//  2. Pin the cases where the REPLACED variants behaved differently — the
//     consolidation is only behaviour-preserving for some of them, and the ones
//     that changed are named explicitly below rather than left to be discovered.

@Suite("trimmedOrNil")
struct TrimmedOrNilTests {
    @Test("Trims surrounding whitespace and returns the trimmed value")
    func trimsAndReturns() {
        #expect("  hi  ".trimmedOrNil == "hi")
        #expect("hi".trimmedOrNil == "hi")
        #expect("  a b  ".trimmedOrNil == "a b")
    }

    @Test("A blank string is nil")
    func blankIsNil() {
        #expect("".trimmedOrNil == nil)
        #expect("   ".trimmedOrNil == nil)
        #expect("\t".trimmedOrNil == nil)
    }

    // MARK: - The two axes the replaced copies differed on

    @Test("Newlines count as blank — the .whitespaces-only copies disagreed")
    func newlinesAreBlank() {
        // Eight replaced sites trimmed `.whitespaces` only, so a newline-only
        // value survived as a non-nil string and reached the wire. Pasting into
        // a single-line field is enough to produce one. The canonical helper
        // treats it as blank; that is a deliberate behaviour change, toward
        // correctness, and this is the case that proves it.
        #expect("\n".trimmedOrNil == nil)
        #expect("\n\n".trimmedOrNil == nil)
        #expect(" \n ".trimmedOrNil == nil)
        #expect("\r\n".trimmedOrNil == nil)

        // The old `.whitespaces`-only behaviour, transcribed from
        // `ProPaymentSettingsView.trimmedOrNil(_:)` as it stood before removal:
        //     let t = s.trimmingCharacters(in: .whitespaces)
        //     return t.isEmpty ? nil : t
        let oldWhitespacesOnly: (String) -> String? = { s in
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        #expect(oldWhitespacesOnly("\n") == "\n") // ← what used to be sent
        #expect("\n".trimmedOrNil == nil)         // ← what is sent now
    }

    @Test("Non-blank input comes back TRIMMED — the blank-check-only copies did not")
    func returnsTrimmedNotReceiver() {
        // Three replaced sites tested blankness on a trimmed copy but handed
        // back the UNTRIMMED receiver, so "  25.00  " reached the server with
        // its padding intact. Same fingerprint, opposite result.
        //
        // Transcribed from `ProMoneyTrailView`'s `nilIfBlank` before removal:
        //     trimmingCharacters(in: .whitespaces).isEmpty ? nil : self
        let oldBlankCheckOnly: (String) -> String? = { s in
            s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s
        }
        #expect(oldBlankCheckOnly("  25.00  ") == "  25.00  ") // ← was sent padded
        #expect("  25.00  ".trimmedOrNil == "25.00")           // ← trimmed now

        // Both agree that a blank value is nil; they only ever differed on the
        // non-blank branch, which is why this went unnoticed.
        #expect(oldBlankCheckOnly("   ") == nil)
        #expect("   ".trimmedOrNil == nil)
    }

    @Test("Interior whitespace is preserved")
    func interiorPreserved() {
        // Trimming is edges-only — a multi-line note keeps its line breaks.
        #expect("  line one\nline two  ".trimmedOrNil == "line one\nline two")
    }
}
