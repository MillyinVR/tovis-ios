import Foundation
import Testing
@testable import Tovis

// The claim link's delivery-channel marker, as parsed off a tapped Universal
// Link.
//
// The same claim token is delivered by BOTH email and SMS, so the tap alone
// says only "one of these two contacts reached this person" — the signed
// `?via=…&vsig=…` the web delivery stamps on is what names which. The app
// carries it opaquely and hands it back; the server re-checks the signature
// before crediting anything, so nothing here is trusted on its own.
//
// The parser previously read path components only, silently dropping the query
// — so a client who tapped their emailed link IN THE APP was still asked to
// verify that same email, while a client who tapped it on the web was not.

@Suite("Public claim deep link")
struct PublicClaimLinkTests {
    @Test("A plain claim link still parses, with no marker")
    func plainLink() throws {
        let link = try #require(
            PublicClaimLink(url: URL(string: "https://tovis.app/claim/tok_1")!)
        )
        #expect(link.token == "tok_1")
        #expect(link.via == nil)
        #expect(link.vsig == nil)
    }

    @Test("A stamped claim link carries both halves of the marker")
    func stampedLink() throws {
        let link = try #require(
            PublicClaimLink(
                url: URL(string: "https://tovis.app/claim/tok_1?via=email&vsig=abc123")!
            )
        )
        #expect(link.token == "tok_1")
        #expect(link.via == "email")
        #expect(link.vsig == "abc123")
    }

    @Test("The query never leaks into the token")
    func queryDoesNotCorruptTheToken() throws {
        let link = try #require(
            PublicClaimLink(
                url: URL(string: "https://tovis.app/claim/tok_1?via=sms&vsig=xyz")!
            )
        )
        #expect(link.token == "tok_1")
        #expect(link.via == "sms")
    }

    @Test("Half a marker is dropped — it could never validate server-side")
    func halfMarkerIsDropped() throws {
        let viaOnly = try #require(
            PublicClaimLink(url: URL(string: "https://tovis.app/claim/tok_1?via=email")!)
        )
        #expect(viaOnly.via == nil)
        #expect(viaOnly.vsig == nil)

        let sigOnly = try #require(
            PublicClaimLink(url: URL(string: "https://tovis.app/claim/tok_1?vsig=abc")!)
        )
        #expect(sigOnly.via == nil)
        #expect(sigOnly.vsig == nil)
    }

    @Test("An empty marker value is treated as absent, not as an empty string")
    func blankMarkerIsDropped() throws {
        let link = try #require(
            PublicClaimLink(
                url: URL(string: "https://tovis.app/claim/tok_1?via=&vsig=abc")!
            )
        )
        #expect(link.via == nil)
        #expect(link.vsig == nil)
    }

    @Test("A foreign host is still refused, marker or not")
    func foreignHostRefused() {
        #expect(
            PublicClaimLink(
                url: URL(string: "https://evil.example/claim/tok_1?via=email&vsig=abc")!
            ) == nil
        )
    }
}
