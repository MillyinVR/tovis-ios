import Foundation
import Testing
@testable import TovisKit

// The single-look detail (GET /api/v1/looks/{id}).
//
// `lookDetail.json` is a VERBATIM capture of the live local route (a look with a
// before/after pair, a 5★ review, 3 tags and real counters) — not a hand-written
// approximation. Step 8 of this epic proved why that matters: a fixture written
// from the same assumption as the reader agrees with the reader and disagrees
// with the server. It is also contract-validated against the backend's generated
// schema by scripts/contract/validate-fixtures.mjs (→ LooksDetailItemDto).

@Suite("Look detail")
struct LookDetailTests {
    private func loadDetail() throws -> LookDetail {
        let data = try fixture("lookDetail")
        return try JSONDecoder().decode(LookDetailResponse.self, from: data).item
    }

    @Test("Decodes the live payload the backend actually emits")
    func decodesFixture() throws {
        let look = try loadDetail()

        #expect(look.id == "cmrbry49n005vpo0df2x71ceu")
        #expect(look.caption == "Lived-in balayage with soft money piece ✨")
        #expect(look.status == "PUBLISHED")
        #expect(look.visibility == "PUBLIC")
        #expect(look.moderationStatus == "APPROVED")
        #expect(look.publishedAt == "2026-04-18T12:00:00.000Z")

        // The pro rides LooksProProfilePreviewDto — no followerCount on the wire.
        #expect(look.professional.displayName == "TOVIS Test Pro")  // BUSINESS_NAME
        #expect(look.professional.handleLabel == "@tovis-test-pro")
        #expect(look.professional.professionType == "COSMETOLOGIST")
        #expect(look.professional.location == "Los Angeles, CA")

        // A pro-authored look credits no client author.
        #expect(look.clientAuthor == nil)

        #expect(look.service?.name == "Balayage")
        #expect(look.service?.category?.name == "Color")
        #expect(look.service?.category?.slug == "hair-color")

        #expect(look.primaryMedia.id == "cmrbry49h005hpo0dx44nzvlr")
        #expect(look.primaryMedia.isVideo == false)
        #expect(look.tags.map(\.slug) == ["balayage", "lived-in-color", "money-piece"])
        #expect(look.tags.map(\.display) == ["balayage", "livedInColor", "moneyPiece"])
    }

    @Test("Carries all five counters — three of which the feed does not have")
    func counts() throws {
        let look = try loadDetail()
        #expect(look.count.likes == 128)
        #expect(look.count.comments == 2)
        // saves/shares/views are detail-only; the feed's _count has likes+comments.
        #expect(look.count.saves == 42)
        #expect(look.count.shares == 7)
        #expect(look.count.views == 2304)
    }

    @Test("Resolves the viewer's permissions")
    func viewerContext() throws {
        let look = try loadDetail()
        // Captured unauthenticated: a guest may read, and may not own it.
        #expect(look.viewerContext.isAuthenticated == false)
        #expect(look.viewerContext.viewerLiked == false)
        #expect(look.viewerContext.viewerSaved == false)
        #expect(look.viewerContext.isOwner == false)
        #expect(look.viewerContext.canComment == true)
        #expect(look.viewerContext.canSave == true)
    }

    @Test("A paired image yields the before/after reveal")
    func beforeAfterPair() throws {
        let look = try loadDetail()
        let pair = try #require(look.beforeAfterPair)
        #expect(pair.before.absoluteString.hasSuffix("/seed/look-2.png"))
        #expect(pair.after.absoluteString.hasSuffix("/seed/look-1.png"))
        #expect(pair.after.absoluteString == look.primaryMedia.url)
    }

    @Test("The review renders web's clamped star string")
    func review() throws {
        let look = try loadDetail()
        let review = try #require(look.review)
        #expect(review.rating == 5)
        #expect(review.headline == "Best balayage I have ever had")
        #expect(review.stars == "★★★★★")
        #expect(review.helpfulLabel == "Helpful: 12")
    }

    @Test("The star string is always 5 glyphs, whatever the rating claims")
    func starsAreClamped() {
        // Web does `'★'.repeat(clamp(rating,0,5)).padEnd(5,'☆')`; a rating
        // outside 0…5 must not produce a runaway or truncated string.
        func stars(_ rating: Int) -> String {
            LookDetailReview(id: "r", rating: rating, headline: nil, helpfulCount: 0).stars
        }
        #expect(stars(3) == "★★★☆☆")
        #expect(stars(0) == "☆☆☆☆☆")
        #expect(stars(5) == "★★★★★")
        #expect(stars(9) == "★★★★★")     // clamped high
        #expect(stars(-2) == "☆☆☆☆☆")    // clamped low
        #expect(stars(9).count == 5)
        #expect(stars(-2).count == 5)
    }

    // A deliberate divergence from web, which renders "Helpful: 0" always.
    @Test("Helpful line hides at zero rather than reading as a criticism")
    func helpfulHidesAtZero() {
        let none = LookDetailReview(id: "r", rating: 4, headline: nil, helpfulCount: 0)
        #expect(none.helpfulLabel == nil)
        let some = LookDetailReview(id: "r", rating: 4, headline: nil, helpfulCount: 1)
        #expect(some.helpfulLabel == "Helpful: 1")
    }

    @Test("The primary asset never repeats in the 'more from this post' grid")
    func secondaryAssetsExcludePrimary() throws {
        let look = try loadDetail()
        // The captured look has exactly one asset — the primary — so the grid is
        // empty rather than showing the hero image a second time.
        #expect(look.assets.count == 1)
        #expect(look.secondaryAssets.isEmpty)
    }
}
