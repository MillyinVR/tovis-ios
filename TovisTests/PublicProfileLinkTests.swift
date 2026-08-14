import Foundation
import Testing
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
}
