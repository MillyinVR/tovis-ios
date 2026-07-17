import Foundation
import Testing
@testable import TovisKit

// The public display-name rule — the Swift port of the web
// `pickProfessionalPublicDisplayName` / `formatProfessionalPublicDisplayName`
// pair (tovis-app/lib/privacy/professionalDisplayName.ts).
//
// These are CHARACTERIZATION tests: they were written against the three
// hand-rolled copies that predated `ProPublicNameSource` and pin the behavior
// those copies actually had — including the three DIFFERENT fallback strings,
// which no test pinned before. That gap is why the drift went unnoticed: the
// fallback is only reachable when a pro has no usable name token at all, so a
// naive "consolidate to one string" refactor would have changed rendered names
// on two of the three surfaces and stayed green.
//
// The load-bearing invariant is web's: BUSINESS_NAME (and unknown/absent, which
// fold into it) NEVER falls through to the handle — only REAL_NAME and HANDLE
// mode may surface an @handle.

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

/// Every field absent but `id` (+ `followerCount`, which `LooksProfessional`
/// requires) — the name-starvation case that reaches the fallback.
private let starved = #"{"id":"p1","followerCount":0}"#

@Suite("Pro public display name")
struct ProPublicDisplayNameTests {
    // MARK: - The web invariant: BUSINESS_NAME never falls to the handle

    @Test("BUSINESS_NAME prefers business, then real name, and never the handle")
    func businessNameMode() throws {
        let business = try decode(BookingProfessional.self, #"""
        {"id":"p1","businessName":"Studio Lux","firstName":"Dana","lastName":"Lee",
         "handle":"dana","nameDisplay":"BUSINESS_NAME"}
        """#)
        #expect(business.displayName == "Studio Lux")

        let real = try decode(BookingProfessional.self, #"""
        {"id":"p1","firstName":"Dana","lastName":"Lee","handle":"dana",
         "nameDisplay":"BUSINESS_NAME"}
        """#)
        #expect(real.displayName == "Dana Lee")

        // No business, no real name, but a handle IS present: web returns null
        // here rather than the handle, so this must be the fallback.
        let handleOnly = try decode(BookingProfessional.self, #"""
        {"id":"p1","handle":"dana","nameDisplay":"BUSINESS_NAME"}
        """#)
        #expect(handleOnly.displayName == "Your pro")
    }

    @Test("REAL_NAME degrades real -> business -> @handle")
    func realNameMode() throws {
        let real = try decode(BookingProfessional.self, #"""
        {"id":"p1","businessName":"Studio Lux","firstName":"Dana","lastName":"Lee",
         "handle":"dana","nameDisplay":"REAL_NAME"}
        """#)
        #expect(real.displayName == "Dana Lee")

        let business = try decode(BookingProfessional.self, #"""
        {"id":"p1","businessName":"Studio Lux","handle":"dana","nameDisplay":"REAL_NAME"}
        """#)
        #expect(business.displayName == "Studio Lux")

        let handle = try decode(BookingProfessional.self, #"""
        {"id":"p1","handle":"dana","nameDisplay":"REAL_NAME"}
        """#)
        #expect(handle.displayName == "@dana")
    }

    @Test("HANDLE degrades @handle -> business -> real")
    func handleMode() throws {
        let handle = try decode(BookingProfessional.self, #"""
        {"id":"p1","businessName":"Studio Lux","firstName":"Dana","lastName":"Lee",
         "handle":"dana","nameDisplay":"HANDLE"}
        """#)
        #expect(handle.displayName == "@dana")

        let business = try decode(BookingProfessional.self, #"""
        {"id":"p1","businessName":"Studio Lux","firstName":"Dana","lastName":"Lee",
         "nameDisplay":"HANDLE"}
        """#)
        #expect(business.displayName == "Studio Lux")

        let real = try decode(BookingProfessional.self, #"""
        {"id":"p1","firstName":"Dana","lastName":"Lee","nameDisplay":"HANDLE"}
        """#)
        #expect(real.displayName == "Dana Lee")
    }

    @Test("An unknown or absent nameDisplay folds into BUSINESS_NAME")
    func unknownMode() throws {
        let unknown = try decode(BookingProfessional.self, #"""
        {"id":"p1","businessName":"Studio Lux","handle":"dana","nameDisplay":"SOMETHING_NEW"}
        """#)
        #expect(unknown.displayName == "Studio Lux")

        let absent = try decode(BookingProfessional.self, #"""
        {"id":"p1","businessName":"Studio Lux","handle":"dana"}
        """#)
        #expect(absent.displayName == "Studio Lux")

        // …and folding into BUSINESS_NAME means it must not reach the handle.
        let handleOnly = try decode(BookingProfessional.self, #"{"id":"p1","handle":"dana"}"#)
        #expect(handleOnly.displayName == "Your pro")
    }

    // MARK: - Blank-token handling

    @Test("Whitespace-only tokens are treated as absent, not rendered blank")
    func blankTokens() throws {
        let pro = try decode(BookingProfessional.self, #"""
        {"id":"p1","businessName":"   ","firstName":"Dana","lastName":"Lee",
         "nameDisplay":"BUSINESS_NAME"}
        """#)
        #expect(pro.displayName == "Dana Lee")

        let blankHandle = try decode(BookingProfessional.self, #"""
        {"id":"p1","handle":"   ","nameDisplay":"HANDLE"}
        """#)
        #expect(blankHandle.displayName == "Your pro")
    }

    @Test("A lone first or last name still resolves (no stray separator)")
    func partialRealName() throws {
        let firstOnly = try decode(BookingProfessional.self, #"""
        {"id":"p1","firstName":"Dana","nameDisplay":"REAL_NAME"}
        """#)
        #expect(firstOnly.displayName == "Dana")

        let lastOnly = try decode(BookingProfessional.self, #"""
        {"id":"p1","lastName":"Lee","nameDisplay":"REAL_NAME"}
        """#)
        #expect(lastOnly.displayName == "Lee")
    }

    // MARK: - The three fallbacks — DIFFERENT per surface, and now pinned

    @Test("Each surface keeps its own distinct starvation fallback")
    func perSurfaceFallbacks() throws {
        // These three strings are deliberately different and are user-visible.
        // They drifted precisely because nothing pinned them; do not unify them
        // without deciding the copy on purpose.
        #expect(try decode(BookingProfessional.self, starved).displayName == "Your pro")
        #expect(try decode(MeProPreview.self, starved).displayName == "Professional")
        #expect(try decode(LooksProfessional.self, starved).displayName == "A pro")
    }

    // MARK: - All three ports share one rule

    @Test("MeProPreview resolves identically to BookingProfessional")
    func meProPreviewParity() throws {
        let handle = try decode(MeProPreview.self, #"""
        {"id":"p1","businessName":"Studio Lux","handle":"dana","nameDisplay":"HANDLE"}
        """#)
        #expect(handle.displayName == "@dana")

        let businessOnly = try decode(MeProPreview.self, #"""
        {"id":"p1","handle":"dana","nameDisplay":"BUSINESS_NAME"}
        """#)
        #expect(businessOnly.displayName == "Professional")  // not "@dana"
    }

    @Test("LooksProfessional resolves identically, and exposes handleLabel")
    func looksProfessionalParity() throws {
        let handle = try decode(LooksProfessional.self, #"""
        {"id":"p1","businessName":"Studio Lux","handle":"dana","nameDisplay":"HANDLE",
         "followerCount":12}
        """#)
        #expect(handle.displayName == "@dana")
        #expect(handle.handleLabel == "@dana")

        let businessOnly = try decode(LooksProfessional.self, #"""
        {"id":"p1","handle":"dana","nameDisplay":"BUSINESS_NAME","followerCount":0}
        """#)
        #expect(businessOnly.displayName == "A pro")  // not "@dana"

        // handleLabel is independent of the mode and nil when there's no handle.
        #expect(try decode(LooksProfessional.self, starved).handleLabel == nil)
    }
}
