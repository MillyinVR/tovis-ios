import Foundation
import Testing
import TovisKit
@testable import Tovis

// Where a tapped `/u/{handle}` link goes.
//
// `PublicClientViewerView` has had eight in-app entry points for a long time,
// but the one route a STRANGER actually arrives by — a shared profile link —
// fell through `PushDeepLink` to nil and bounced out to Safari, while the
// narrower `/u/{handle}/boards/{slug}` opened natively. This is the link the
// client Share sheet promises ("a Recreate this look link back to your
// profile"), so these pin both halves: the profile now routes, and it does not
// swallow the board link that has its own parser and its own screen.

@Suite("Public profile deep link")
struct PublicProfileLinkTests {
    @Test("A shared /u/{handle} opens the native creator profile")
    func profileRoutes() {
        #expect(
            PushDeepLink(href: "/u/maya-reyes")?.target == .publicClient(handle: "maya-reyes")
        )
        #expect(
            PushDeepLink(href: "https://tovis.app/u/maya-reyes")?.target
                == .publicClient(handle: "maya-reyes")
        )
    }

    @Test("Either shell can open it, so no workspace switch is forced")
    func profileIsRoleAgnostic() {
        // A pro opens the same screen from their client roster (ProClientsView).
        // A non-nil role here would bounce a pro out of their own workspace.
        #expect(PushDeepLink(href: "/u/maya-reyes")?.role == nil)
    }

    @Test("The board link is left to its own parser")
    func boardLinkIsNotSwallowed() {
        // `PublicBoardLink` → PublicBoardView. If the profile case claimed this
        // too, a tapped board link would land on the profile instead of the
        // board the sender meant.
        #expect(PushDeepLink(href: "/u/maya-reyes/boards/lived-in-blonde") == nil)
    }

    @Test("A handle-less /u path resolves nothing")
    func emptyHandleStaysNil() {
        #expect(PushDeepLink(href: "/u") == nil)
        #expect(PushDeepLink(href: "/u/") == nil)
    }

    @Test("A shared /professionals/{id} resolves the pro profile")
    func proProfileResolves() {
        #expect(
            PushDeepLink(href: "/professionals/pro_123")?.target
                == .publicPro(professionalId: "pro_123")
        )
        #expect(PushDeepLink(href: "/professionals") == nil)
        #expect(PushDeepLink(href: "/professionals/") == nil)
        // Not the pro list, not a sub-page — only the profile itself.
        #expect(PushDeepLink(href: "/professionals/pro_123/reviews") == nil)
    }
}

// Where a TAPPED public-profile Universal Link goes.
//
// 🔴 The suite above pins the PUSH parser, and it passed the whole time the
// feature was broken: `handleDeepLink(url:)` — the one entry point `.onOpenURL`
// calls — never consulted `PushDeepLink` at all. `/u/*` is associated in the
// AASA, so a tapped creator profile opened the app and did nothing, and
// `/professionals/*` (the pro-side twin the profile's own Share control emits)
// was not associated at all. These drive the handler, not the parser, because
// the handler is the half that was missing.
@MainActor
@Suite("Public profile Universal Link")
struct PublicProfileUniversalLinkTests {
    private func session() -> SessionModel {
        SessionModel(config: TovisConfig(baseURL: URL(string: "https://www.tovis.app/api/v1")!))
    }

    @Test("A tapped /u/{handle} link opens the native creator profile")
    func creatorProfileRoutes() {
        let model = session()
        model.handleDeepLink(URL(string: "https://www.tovis.app/u/maya-reyes")!)
        #expect(model.pushDeepLink?.target == .publicClient(handle: "maya-reyes"))
    }

    @Test("A tapped /professionals/{id} link opens the native pro profile")
    func proProfileRoutes() {
        // Exactly what `ProProfileView.shareURL` puts on the share sheet.
        let model = session()
        model.handleDeepLink(URL(string: "https://www.tovis.app/professionals/pro_123")!)
        #expect(model.pushDeepLink?.target == .publicPro(professionalId: "pro_123"))
    }

    @Test("The apex host routes too")
    func apexHostRoutes() {
        let model = session()
        model.handleDeepLink(URL(string: "https://tovis.app/professionals/pro_123")!)
        #expect(model.pushDeepLink?.target == .publicPro(professionalId: "pro_123"))
    }

    @Test("A tracking parameter picked up along the way is ignored, not fatal")
    func queryParametersAreIgnored() {
        // A share link often comes back pasted from a browser with something
        // appended. The path is what resolves the profile; the rest is noise.
        let model = session()
        model.handleDeepLink(URL(string: "https://www.tovis.app/professionals/pro_123?ref=sms#top")!)
        #expect(model.pushDeepLink?.target == .publicPro(professionalId: "pro_123"))
    }

    @Test("A board share link still lands on the board, not the profile")
    func boardLinkIsNotStolen() {
        // `PublicBoardLink` runs first and has its own screen. If the profile
        // branch claimed this, a tapped board link would open the profile.
        let model = session()
        model.handleDeepLink(URL(string: "https://www.tovis.app/u/maya-reyes/boards/lived-in-blonde")!)
        #expect(model.pendingPublicBoard == PublicBoardLink(url: URL(string: "https://www.tovis.app/u/maya-reyes/boards/lived-in-blonde")!))
        #expect(model.pushDeepLink == nil)
    }

    @Test("The handle-keyed pro mirror /p/{handle} is not claimed")
    func handleKeyedMirrorStaysOnTheWeb() {
        // Resolving a handle to a professionalId needs a lookup this parser
        // cannot do, so `/p/*` is deliberately absent from the AASA as well.
        let model = session()
        model.handleDeepLink(URL(string: "https://www.tovis.app/p/maya-reyes")!)
        #expect(model.pushDeepLink == nil)
    }

    @Test("A path with no id resolves nothing")
    func emptyIdStaysNil() {
        let model = session()
        model.handleDeepLink(URL(string: "https://www.tovis.app/professionals")!)
        #expect(model.pushDeepLink == nil)
        model.handleDeepLink(URL(string: "https://www.tovis.app/professionals/pro_1/reviews")!)
        #expect(model.pushDeepLink == nil)
    }

    @Test("Another host cannot open a profile in the app")
    func foreignHostIsRefused() {
        // `.onOpenURL` hands over any URL the app is asked to open — the host is
        // re-checked here for the same reason every other link parser re-checks it.
        let model = session()
        model.handleDeepLink(URL(string: "https://evil.example/professionals/pro_123")!)
        #expect(model.pushDeepLink == nil)
        model.handleDeepLink(URL(string: "http://www.tovis.app/professionals/pro_123")!)
        #expect(model.pushDeepLink == nil)
    }
}
