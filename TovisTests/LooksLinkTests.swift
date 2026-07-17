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
        // The app renders these in every look's tag chips; they open in Safari.
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

@Suite("Push deep link — looks")
struct PushDeepLinkLooksTests {
    @Test("A /looks/{id} href targets the look")
    func parsesLookHref() {
        #expect(PushDeepLink(href: "/looks/look_123")?.target == .look(id: "look_123"))
    }

    @Test("A tag href does not target a look")
    func rejectsTagHref() {
        // Previously produced `.look(id: "tags")`.
        #expect(PushDeepLink(href: "/looks/tags/balayage") == nil)
    }

    @Test("Either shell opens a look — no workspace switch")
    func lookHasNoRole() {
        #expect(PushDeepLink(href: "/looks/look_123")?.role == nil)
    }
}
