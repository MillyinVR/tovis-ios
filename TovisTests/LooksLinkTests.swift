import Foundation
import Testing
@testable import Tovis

// The two ways a single look gets opened: a tapped push href (`PushDeepLink`)
// and a tapped Universal Link (`LooksLink`). Both resolve the id through
// `LooksPath`, so these pin that they agree.

@Suite("Looks path parsing")
struct LooksPathTests {
    @Test("A /looks/{id} path yields the id")
    func resolvesLookId() {
        #expect(LooksPath.lookId(from: ["looks", "look_123"]) == "look_123")
    }

    // ⚠️ The regression this guard exists for. `/looks/tags/{slug}` is a TAG
    // page; the old parser took parts[1] for ANY /looks/* path and produced
    // `.look(id: "tags")`. That was invisible while the id was discarded and the
    // shell just showed the feed — wiring the id to a real fetch turns it into a
    // guaranteed 404 on a link the app itself renders in every look's tag chips.
    @Test("A tag page is never mistaken for a look")
    func tagPageIsNotALook() {
        #expect(LooksPath.lookId(from: ["looks", "tags", "balayage"]) == nil)
        // …and the bare /looks/tags page is not a look called "tags" either.
        #expect(LooksPath.lookId(from: ["looks", "tags"]) == nil)
        #expect(LooksPath.lookId(from: ["looks", "TAGS"]) == nil)
    }

    @Test("The feed root is not a look")
    func feedRootIsNotALook() {
        #expect(LooksPath.lookId(from: ["looks"]) == nil)
        #expect(LooksPath.lookId(from: []) == nil)
    }

    @Test("A deeper unknown sub-path is not a look")
    func deeperPathIsNotALook() {
        // Guard against a future /looks/{id}/something being read as the id.
        #expect(LooksPath.lookId(from: ["looks", "look_123", "extra"]) == nil)
    }

    @Test("Another section's path is not a look")
    func otherSectionIsNotALook() {
        #expect(LooksPath.lookId(from: ["boards", "b1"]) == nil)
    }

    @Test("A /looks/tags/{slug} path yields the slug")
    func resolvesTagSlug() {
        #expect(LooksPath.tagSlug(from: ["looks", "tags", "balayage"]) == "balayage")
    }

    // The slug is normalized the way web's `slugifyLookTag` does — lowercase,
    // ascii alphanumerics only — so the key sent to GET /looks?tag= is the key
    // the web page resolves, whatever casing the tapped URL carried.
    @Test("The slug is normalized like web's slugifyLookTag")
    func normalizesTagSlug() {
        #expect(LooksPath.tagSlug(from: ["looks", "tags", "Balayage"]) == "balayage")
        #expect(LooksPath.tagSlug(from: ["looks", "tags", "90s_Blowout"]) == "90sblowout")
        #expect(LooksPath.tagSlug(from: ["looks", "tags", "café"]) == "caf")
    }

    // Web's own validity floor: `parseLookTags` drops anything that normalizes
    // below two characters and `loadLookTagPage` 404s it, so there is no screen
    // to open — and the server 400s a sub-2-char `tag` param.
    @Test("A slug that normalizes below two characters is not a tag")
    func rejectsShortTagSlug() {
        #expect(LooksPath.tagSlug(from: ["looks", "tags", "a"]) == nil)
        #expect(LooksPath.tagSlug(from: ["looks", "tags", "--"]) == nil)
        #expect(LooksPath.tagSlug(from: ["looks", "tags", ""]) == nil)
    }

    @Test("The bare tags index and a look are not tag pages")
    func rejectsNonTagPaths() {
        // Web has no /looks/tags index page — only /looks/tags/[slug].
        #expect(LooksPath.tagSlug(from: ["looks", "tags"]) == nil)
        #expect(LooksPath.tagSlug(from: ["looks", "look_123"]) == nil)
        #expect(LooksPath.tagSlug(from: ["looks", "tags", "balayage", "extra"]) == nil)
        #expect(LooksPath.tagSlug(from: ["boards", "tags", "balayage"]) == nil)
    }
}

@Suite("Looks universal link")
struct LooksLinkTests {
    @Test("Opens the URL the app's own share sheet generates")
    func parsesShareURL() throws {
        // LooksView.shareURL builds exactly this.
        let url = try #require(URL(string: "https://www.tovis.app/looks/look_123"))
        #expect(LooksLink(url: url)?.id == "look_123")
    }

    @Test("Accepts the apex host too")
    func parsesApexHost() throws {
        let url = try #require(URL(string: "https://tovis.app/looks/look_123"))
        #expect(LooksLink(url: url)?.id == "look_123")
    }

    @Test("A query string doesn't leak into the id")
    func ignoresQuery() throws {
        let url = try #require(URL(string: "https://www.tovis.app/looks/look_123?utm_source=ig"))
        #expect(LooksLink(url: url)?.id == "look_123")
    }

    @Test("A tag link is not a look link")
    func rejectsTagLink() throws {
        // Still not a LOOK — it is a tag page, and `LookTagLink` below claims it.
        let url = try #require(URL(string: "https://www.tovis.app/looks/tags/balayage"))
        #expect(LooksLink(url: url) == nil)
    }

    @Test("Rejects a foreign host and a non-https scheme")
    func rejectsForeignURLs() throws {
        let foreign = try #require(URL(string: "https://evil.example.com/looks/look_123"))
        #expect(LooksLink(url: foreign) == nil)

        let lookalike = try #require(URL(string: "https://tovis.app.evil.com/looks/look_123"))
        #expect(LooksLink(url: lookalike) == nil)

        let insecure = try #require(URL(string: "http://www.tovis.app/looks/look_123"))
        #expect(LooksLink(url: insecure) == nil)
    }

    @Test("Other tovis pages are left to their own parsers")
    func rejectsOtherPages() throws {
        let board = try #require(URL(string: "https://www.tovis.app/u/tori/boards/bridal"))
        #expect(LooksLink(url: board) == nil)

        let feed = try #require(URL(string: "https://www.tovis.app/looks"))
        #expect(LooksLink(url: feed) == nil)
    }
}

// The tag page's own Universal Link. `/looks/tags/*` was EXCLUDED from the AASA
// file because "native has no tag screen" — a premise that expired when
// LookTagFeedView replaced the three SafariView ejects. These pin the app half:
// web must not associate the path unless a tapped link resolves to a screen,
// because an associated path the app doesn't route is a silent no-op.
@Suite("Look tag universal link")
struct LookTagLinkTests {
    @Test("Opens the tag page the app's own chips link to")
    func parsesTagURL() throws {
        let url = try #require(URL(string: "https://www.tovis.app/looks/tags/balayage"))
        #expect(LookTagLink(url: url)?.slug == "balayage")
    }

    @Test("Accepts the apex host too")
    func parsesApexHost() throws {
        let url = try #require(URL(string: "https://tovis.app/looks/tags/balayage"))
        #expect(LookTagLink(url: url)?.slug == "balayage")
    }

    @Test("A query string doesn't leak into the slug")
    func ignoresQuery() throws {
        let url = try #require(URL(string: "https://www.tovis.app/looks/tags/balayage?utm_source=ig"))
        #expect(LookTagLink(url: url)?.slug == "balayage")
    }

    @Test("A single look is not a tag page")
    func rejectsLookLink() throws {
        let url = try #require(URL(string: "https://www.tovis.app/looks/look_123"))
        #expect(LookTagLink(url: url) == nil)
    }

    @Test("Rejects a foreign host and a non-https scheme")
    func rejectsForeignURLs() throws {
        let foreign = try #require(URL(string: "https://evil.example.com/looks/tags/balayage"))
        #expect(LookTagLink(url: foreign) == nil)

        let lookalike = try #require(URL(string: "https://tovis.app.evil.com/looks/tags/balayage"))
        #expect(LookTagLink(url: lookalike) == nil)

        let insecure = try #require(URL(string: "http://www.tovis.app/looks/tags/balayage"))
        #expect(LookTagLink(url: insecure) == nil)
    }

    // `pathComponents` decodes and drops a trailing slash, so both shapes a real
    // share/paste can produce resolve to the same slug — pinned because the
    // parser's `parts.count == 3` would otherwise be quietly shape-sensitive.
    @Test("A trailing slash and percent-encoding still resolve")
    func toleratesURLShapes() throws {
        let trailing = try #require(URL(string: "https://www.tovis.app/looks/tags/balayage/"))
        #expect(LookTagLink(url: trailing)?.slug == "balayage")

        let encoded = try #require(URL(string: "https://www.tovis.app/looks/tags/Bal%20ayage"))
        #expect(LookTagLink(url: encoded)?.slug == "balayage")
    }

    // The bare index stays EXCLUDED in the AASA file for exactly this reason:
    // web has no /looks/tags page, and neither does the app.
    @Test("The bare tags index is not a tag page")
    func rejectsTagsIndex() throws {
        let url = try #require(URL(string: "https://www.tovis.app/looks/tags"))
        #expect(LookTagLink(url: url) == nil)
    }
}

@Suite("Push deep link — looks")
struct PushDeepLinkLooksTests {
    @Test("A /looks/{id} href targets the look")
    func parsesLookHref() {
        #expect(PushDeepLink(href: "/looks/look_123")?.target == .look(id: "look_123", book: false))
    }

    @Test("A tag href does not target a look")
    func rejectsTagHref() {
        // Previously produced `.look(id: "tags")`. Still nil, and deliberately so
        // even though a tapped /looks/tags/{slug} URL now opens the native tag
        // feed: that route is set from `LookTagLink`, not from an href, so the
        // notification surfaces keep the behaviour their own tests pin.
        #expect(PushDeepLink(href: "/looks/tags/balayage") == nil)
    }

    // ⚠️ `?book=1` is the web's open-the-availability-sheet-on-arrival flag, and
    // it is what "Recreate this look" links to. It used to be dropped here, so
    // the same link opened the sheet on web and stopped at the look on a phone.
    @Test("book=1 asks for the booking sheet")
    func parsesBookFlag() {
        #expect(
            PushDeepLink(href: "/looks/look_123?book=1")?.target
                == .look(id: "look_123", book: true),
        )
    }

    @Test("Any other book value is not a booking request")
    func ignoresOtherBookValues() {
        #expect(
            PushDeepLink(href: "/looks/look_123?book=0")?.target
                == .look(id: "look_123", book: false),
        )
        #expect(
            PushDeepLink(href: "/looks/look_123?book=yes")?.target
                == .look(id: "look_123", book: false),
        )
    }

    @Test("Either shell opens a look — no workspace switch")
    func lookHasNoRole() {
        #expect(PushDeepLink(href: "/looks/look_123")?.role == nil)
    }
}
