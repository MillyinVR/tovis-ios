// The signed-in PRO footer tabs — ported 1:1 from the web's `ProSessionFooter`
// (Looks · Calendar · [center live-session button] · Messages · Profile) so iOS
// and web stay in lock-step for a pro who moves between devices.
//
// Unlike the client bar, the CENTER slot is NOT a tab — it's the live-session
// action button (its own state machine). So there are four real tabs here; the
// center is handled separately by `ProTabBar` + `ProSessionModel`.
import SwiftUI

struct ProTab: Identifiable, Hashable {
    // `overview` is the dedicated Overview-home surface (hosts the web top-header
    // tab strip). It is NOT a footer slot — `ProNav.tabs` below keeps the web
    // `ProSessionFooter` 5 slots — and it is no longer the launch selection: pros
    // land on Calendar (matching web `/pro` → `/pro/calendar`), and reach the
    // Overview home via the Home control on the Calendar bar.
    enum ID: String, Hashable { case overview, looks, calendar, messages, profile }

    let id: ID
    let label: String
    /// SF Symbol chosen to mirror the web's lucide icon.
    let systemImage: String
    /// Whether this tab can show an unread badge (Messages, like the web).
    var hasBadge: Bool = false
}

enum ProNav {
    // web ProSessionFooter icon mapping:
    //   Looks → brand TovisEye mark (rendered by ProTabBar, like web <BrandMark/>;
    //     systemImage is an unused fallback) · CalendarDays → calendar ·
    //   MessageCircle → message · User → person
    static let tabs: [ProTab] = [
        ProTab(id: .looks,    label: "Looks",    systemImage: "sparkles"),
        ProTab(id: .calendar, label: "Calendar", systemImage: "calendar"),
        // center: live-session button (ProTabBar) — occupies slot 3
        ProTab(id: .messages, label: "Messages", systemImage: "message", hasBadge: true),
        ProTab(id: .profile,  label: "Profile",  systemImage: "person"),
    ]
}
