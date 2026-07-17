import Foundation
import Testing
@testable import Tovis

// A tapped `/c/<shortCode>` referral Universal Link — the invite card + its QR emit
// exactly this (`ClientInviteCard` / `QRCodeImage`). It parses to the short code and a
// CANONICAL `www.tovis.app` funnel URL rebuilt from the validated code (never the raw
// onOpenURL URL), which RootView opens in the in-app browser.

@Suite("Client-referral universal link")
struct PublicReferralLinkTests {
    @Test("Parses the URL the invite card / QR emits")
    func parsesInviteURL() throws {
        // ClientInviteCard.shareURL / QRCodeImage encode exactly this (web decode
        // pinned it as https://www.tovis.app/c/DMFTWB7W in step 16).
        let url = try #require(URL(string: "https://www.tovis.app/c/DMFTWB7W"))
        let link = try #require(PublicReferralLink(url: url))
        #expect(link.shortCode == "DMFTWB7W")
        #expect(link.url.absoluteString == "https://www.tovis.app/c/DMFTWB7W")
    }

    @Test("Accepts the apex host but always opens the www funnel URL")
    func normalizesApexHost() throws {
        let url = try #require(URL(string: "https://tovis.app/c/DMFTWB7W"))
        let link = try #require(PublicReferralLink(url: url))
        // The canonical URL is rebuilt on www.tovis.app regardless of input host, so
        // the browser skips the apex→www redirect hop.
        #expect(link.url.absoluteString == "https://www.tovis.app/c/DMFTWB7W")
    }

    @Test("A query string doesn't leak into the opened URL")
    func dropsQuery() throws {
        // The web funnel ignores query params; the canonical URL is code-only, so a
        // tracking/query suffix is dropped rather than forwarded into the browser.
        let url = try #require(URL(string: "https://www.tovis.app/c/DMFTWB7W?utm_source=ig"))
        let link = try #require(PublicReferralLink(url: url))
        #expect(link.shortCode == "DMFTWB7W")
        #expect(link.url.absoluteString == "https://www.tovis.app/c/DMFTWB7W")
    }

    @Test("Rejects a foreign host and a non-https scheme")
    func rejectsForeignURLs() throws {
        let foreign = try #require(URL(string: "https://evil.example.com/c/DMFTWB7W"))
        #expect(PublicReferralLink(url: foreign) == nil)

        let lookalike = try #require(URL(string: "https://tovis.app.evil.com/c/DMFTWB7W"))
        #expect(PublicReferralLink(url: lookalike) == nil)

        let insecure = try #require(URL(string: "http://www.tovis.app/c/DMFTWB7W"))
        #expect(PublicReferralLink(url: insecure) == nil)
    }

    @Test("A hostile or malformed short code can't ride into the browser")
    func rejectsBadShortCodes() throws {
        // Non-alphanumerics (the raw code is Crockford base32); anything else is left
        // to fall through rather than opening an unexpected URL in-app.
        let bare = try #require(URL(string: "https://www.tovis.app/c"))
        #expect(PublicReferralLink(url: bare) == nil)

        let empty = try #require(URL(string: "https://www.tovis.app/c/"))
        #expect(PublicReferralLink(url: empty) == nil)

        // A deeper path is not a `/c/<code>` link.
        let deeper = try #require(URL(string: "https://www.tovis.app/c/DMFTWB7W/extra"))
        #expect(PublicReferralLink(url: deeper) == nil)

        // A code with a slash-y / spaced / punctuated segment.
        if let dotted = URL(string: "https://www.tovis.app/c/AB.CD") {
            #expect(PublicReferralLink(url: dotted) == nil)
        }
    }

    @Test("Other tovis pages are left to their own parsers")
    func rejectsOtherPages() throws {
        let claim = try #require(URL(string: "https://www.tovis.app/claim/tok_123"))
        #expect(PublicReferralLink(url: claim) == nil)

        let look = try #require(URL(string: "https://www.tovis.app/looks/look_123"))
        #expect(PublicReferralLink(url: look) == nil)

        let board = try #require(URL(string: "https://www.tovis.app/u/tori/boards/bridal"))
        #expect(PublicReferralLink(url: board) == nil)
    }
}
