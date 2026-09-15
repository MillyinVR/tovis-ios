// TovisTests/LookTagSlugParityTests.swift
//
// Holds the Swift slug twin to WEB's rule, not to a remembered version of it.
//
// `LooksPath.slugifyTag` / `LooksPath.tagSlug` reimplement tovis-app's
// `slugifyLookTag` / `resolveLookTagSlug` so a tapped `/looks/tags/{slug}`
// Universal Link resolves to the same feed the web page would show. Until this
// file existed the only thing checking that twin was a handful of HAND-WRITTEN
// expected values in `LooksLinkTests` — assertions that agree with whoever
// typed them, not with web. If web changed its rule (started keeping hyphens,
// transliterated an accent instead of dropping it), tag links built on web
// would open a different feed, or nothing at all, and both test suites would
// have stayed green.
//
// `Fixtures/lookTagSlugs.json` is GENERATED in tovis-app from the real
// functions (`pnpm gen:look-tag-slug-fixture`) and committed to BOTH repos
// byte-for-byte; tovis-app's `check:ios-parity-fixtures` fails there if this
// copy drifts. So the pairs below are web's actual answers, and this test is
// the thing that makes a rule change on either side visible.
//
// It caught a real divergence the day it was written: the twin filtered
// GRAPHEME CLUSTERS while web filters code units, so a decomposed accent took
// its ASCII base letter down with it (see `slugifyTag`'s own comment).

import Foundation
import Testing

@testable import Tovis

/// One generated `(input, slug, tagSlug)` row.
///
/// `tagSlug` is nullable in the fixture — it is null wherever the slug falls
/// below web's two-character floor, which is the case `LooksPath.tagSlug`
/// answers with nil.
private struct LookTagSlugCase: Decodable {
    let input: String
    let slug: String
    let tagSlug: String?
}

private struct LookTagSlugFixture: Decodable {
    let cases: [LookTagSlugCase]
}

@Suite struct LookTagSlugParityTests {
    private static let fixture: LookTagSlugFixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/lookTagSlugs.json")
        // force-try: a missing or unreadable fixture is a broken checkout, and
        // failing loudly here beats every test below silently passing on zero
        // cases.
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(LookTagSlugFixture.self, from: data)
    }()

    /// The exact code points of a string.
    ///
    /// 🔴 Never compare these inputs as `String`. Swift string equality is
    /// UNICODE CANONICAL EQUIVALENCE, so the precomposed and decomposed
    /// spellings of the accented case compare EQUAL and collapse into one
    /// another in a `Set<String>` — even though web answers them differently
    /// ("caf" vs "cafe") and telling them apart is the whole reason they are
    /// both in the fixture. Scalars are what actually differ, so scalars are
    /// what this compares.
    private static func scalars(_ s: String) -> [UInt32] {
        s.unicodeScalars.map(\.value)
    }

    /// 🔴 Guard the guard. If `cases` were ever empty, the loops below would
    /// iterate nothing and this suite would pass having checked nothing — the
    /// "green because it ran nothing" failure the CI jobs assert against at the
    /// harness level.
    @Test("The generated fixture is present and non-trivial")
    func fixtureLoaded() {
        #expect(Self.fixture.cases.count >= 20)

        // The cases that discriminate must actually be in the file; a fixture
        // regenerated from a gutted input list would otherwise still pass.
        let inputs = Self.fixture.cases.map { Self.scalars($0.input) }
        for required in ["Balayage", "90s_Blowout", "Money-Piece", "--", ""] {
            #expect(inputs.contains(Self.scalars(required)), "missing case \(required.debugDescription)")
        }

        // Precomposed AND decomposed spellings of the same word, which web
        // answers differently. If the committed file were ever NFC-normalized
        // these two would become the same bytes and the sharpest pair in the
        // fixture would quietly become a duplicate.
        let precomposed = Self.scalars("caf\u{00E9}")
        let decomposed = Self.scalars("caf\u{0065}\u{0301}")
        #expect(precomposed != decomposed)
        #expect(inputs.contains(precomposed))
        #expect(inputs.contains(decomposed))

        // No two cases are the same code points — a duplicate means someone
        // lost a discriminator (most likely to normalization).
        #expect(Set(inputs).count == Self.fixture.cases.count)
    }

    /// The normalization itself, over every generated pair.
    ///
    /// Driven through `tagSlug(from:)` — the REAL entry point a tapped link
    /// takes — rather than calling the private `slugifyTag` directly, so the
    /// path guard and the floor are exercised together with the rule.
    @Test("LooksPath.tagSlug reproduces every pair web generated")
    func reproducesWebSlugs() {
        for row in Self.fixture.cases {
            let actual = LooksPath.tagSlug(from: ["looks", "tags", row.input])
            #expect(
                actual == row.tagSlug,
                """
                /looks/tags/\(row.input.debugDescription) \
                — web resolves to \(row.tagSlug.debugDescription), \
                this app resolves to \(actual.debugDescription). \
                web slugifyLookTag said \(row.slug.debugDescription).
                """
            )
        }
    }

    /// The floor, stated separately from the rule it rides on.
    ///
    /// `tagSlug` returns nil below two characters because web's
    /// `resolveLookTagSlug` does — `loadLookTagPage` returns null and the page
    /// 404s, so there is nothing for the app to open either. Asserting it from
    /// the fixture's `slug` column means the floor cannot drift out of step
    /// with the normalization that feeds it.
    @Test("The two-character floor matches web's, in both directions")
    func floorMatchesWeb() {
        var accepted = 0
        var refused = 0
        for row in Self.fixture.cases {
            if row.slug.count >= 2 {
                #expect(row.tagSlug == row.slug, "web accepted \(row.slug.debugDescription)")
                accepted += 1
            } else {
                #expect(row.tagSlug == nil, "web refused \(row.slug.debugDescription)")
                refused += 1
            }
        }
        // Both sides of the floor are actually represented, so this cannot pass
        // by testing only one of them.
        #expect(accepted > 0)
        #expect(refused > 0)
    }
}
