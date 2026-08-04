import Foundation
import Testing
@testable import TovisKit

/// The wire contract behind the two Business rows that used to dead-end on a
/// "Coming soon" screen ("No-show fees", "Import from another app").
///
/// Both are complete features held behind a server env flag, and every endpoint
/// behind those flags 404s while they are off — so the app cannot learn a flag
/// by asking the feature. `GET /api/v1/pro/capabilities` is the one route that
/// answers in that case, and these tests pin the two properties the row-hiding
/// depends on: the payload decodes, and the fallback is OFF.
@Suite struct ProCapabilitiesTests {
    /// Byte-for-byte what the route returns (drove it locally against the dev
    /// stack with a minted PRO token). A key rename server-side breaks this,
    /// which is the point — a silently-failed decode would fall back to `.none`
    /// and quietly hide a live feature forever.
    private func decode(_ json: String) throws -> ProCapabilities {
        struct Envelope: Decodable { let capabilities: ProCapabilities }
        let data = Data(json.utf8)
        return try JSONDecoder().decode(Envelope.self, from: data).capabilities
    }

    @Test func decodesTheFlagsOffPayload() throws {
        let caps = try decode(
            #"{"ok":true,"capabilities":{"noShowFees":false,"importFromAnotherApp":false}}"#
        )
        #expect(caps.noShowFees == false)
        #expect(caps.importFromAnotherApp == false)
    }

    @Test func decodesTheFlagsOnPayload() throws {
        let caps = try decode(
            #"{"ok":true,"capabilities":{"noShowFees":true,"importFromAnotherApp":true}}"#
        )
        #expect(caps.noShowFees == true)
        #expect(caps.importFromAnotherApp == true)
    }

    /// 🔴 The two capabilities must stay independent. A decoder or resolver that
    /// crossed the keys would pass both all-on and all-off cases above and fail
    /// only here — which is exactly the bug that would put ONE dead row back.
    @Test func theTwoCapabilitiesAreIndependent() throws {
        let onlyMigration = try decode(
            #"{"capabilities":{"noShowFees":false,"importFromAnotherApp":true}}"#
        )
        #expect(onlyMigration.noShowFees == false)
        #expect(onlyMigration.importFromAnotherApp == true)

        let onlyNoShow = try decode(
            #"{"capabilities":{"noShowFees":true,"importFromAnotherApp":false}}"#
        )
        #expect(onlyNoShow.noShowFees == true)
        #expect(onlyNoShow.importFromAnotherApp == false)
    }

    /// 🔴 The fail-safe. `.none` is what the profile tab renders with before the
    /// wire answers and after a failed read. Hiding a live row is recoverable —
    /// it comes back on the next load. Offering a dead one is not: it walks the
    /// pro straight into the 404 this whole change exists to remove. If someone
    /// ever "helpfully" flips a default to `true`, this goes red.
    @Test func theFallbackOffersNothing() {
        #expect(ProCapabilities.none.noShowFees == false)
        #expect(ProCapabilities.none.importFromAnotherApp == false)
    }

    /// A truncated / unexpected body must NOT decode into a permissive value —
    /// it must throw, so the caller keeps `.none` rather than inventing `true`.
    @Test func aMissingKeyThrowsRatherThanDefaultingOn() {
        #expect(throws: (any Error).self) {
            try decode(#"{"capabilities":{"noShowFees":true}}"#)
        }
    }
}
