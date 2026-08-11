// The signed-in client footer tabs — ported 1:1 from the web's
// `app/config/clientNav.ts` (CLIENT_TABS) so iOS and web stay in lock-step.
//
// Order + identity match the web exactly: Home · Discover · Looks(center) ·
// Inbox · Me. "Looks" is the home base, so it takes the raised center mark (the
// tovis feather) instead of a plain SF Symbol — see LooksMark.
//
// ⚠️ There is deliberately NO `bookings` tab — bookings live in the home area on
// both platforms. That MOVES a load-bearing constraint rather than dropping it:
// AppointmentsView is the only surface that lists a client's PENDING bookings.
// The home Upcoming card only appears for an ACCEPTED/IN_PROGRESS booking
// (`status: { in: [ACCEPTED, IN_PROGRESS] }` in getClientHomeData) and
// Me → History filters to ACCEPTED/IN_PROGRESS/COMPLETED, so a client whose only
// booking is still PENDING sees the card's "No approved bookings yet" EMPTY
// state. HomeView's UpcomingCard therefore pushes AppointmentsView from BOTH its
// states — populated and empty — so that client can still view, and cancel,
// their own request. Do not make either route conditional.
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