// The signed-in client footer tabs — ported 1:1 from the web's
// `app/config/clientNav.ts` (CLIENT_TABS) so iOS and web stay in lock-step.
//
// Order + identity match the web exactly: Home · Discover · Looks(center) ·
// Inbox · Me. "Looks" is the home base, so it takes the raised center mark
// (the tovis feather) instead of a plain SF Symbol — see LooksMark.
import SwiftUI

struct ClientTab: Identifiable, Hashable {
    enum ID: String, Hashable { case home, discover, looks, inbox, me }

    let id: ID
    let label: String
    /// SF Symbol chosen to mirror the web's lucide icon (unused for the center).
    let systemImage: String
    /// The raised center mark (Looks) renders the feather instead of an icon.
    var center: Bool = false
    /// Whether this tab can show an unread badge (Inbox, like the web).
    var hasBadge: Bool = false
}

enum ClientNav {
    // lucide → SF Symbol mapping:
    //   House → house · Compass → safari · Sparkles → (feather mark) ·
    //   Mail → envelope · User → person
    static let tabs: [ClientTab] = [
        ClientTab(id: .home,     label: "Home",     systemImage: "house"),
        ClientTab(id: .discover, label: "Discover", systemImage: "safari"),
        ClientTab(id: .looks,    label: "Looks",    systemImage: "sparkles", center: true),
        ClientTab(id: .inbox,    label: "Inbox",    systemImage: "envelope", hasBadge: true),
        ClientTab(id: .me,       label: "Me",       systemImage: "person"),
    ]
}