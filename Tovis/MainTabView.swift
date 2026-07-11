// The signed-in shell: the custom Tovis footer over the client surfaces.
//
// Matches the web client footer 1:1 — Home · Discover · Looks(center feather) ·
// Inbox · Me (see ClientTab + TovisTabBar). Appointments is NOT a footer tab
// (the web reaches bookings from the home cards and the Me tab, not the footer);
// HomeView pushes to it, and the Me tab links to it.
//
// Social-first landing: clients open on the Looks feed (the center feather),
// matching the web, where login/verify default a client to `/looks`. Tovis is a
// social platform first, so the feed is always the first thing a client sees.
//
// We keep a real SwiftUI TabView for per-tab state + lazy loading, hide its
// system bar, and overlay our branded bar via safeAreaInset so the raised
// feather can lift above the bar like the web's .tovis-center-lift.
import SwiftUI
import TovisKit

struct MainTabView: View {
    @Environment(SessionModel.self) private var session
    @State private var tab: ClientTab.ID = .looks
    @State private var messagesBadge: String?
    /// A booking surfaced by a tapped push (`tovis://`-style `href` deep link),
    /// presented over the shell. nil when nothing is being deep-linked.
    @State private var deepLinkBooking: ClientBooking?
    /// The `step` carried on that booking deep link (`?step=consult|aftercare|…`),
    /// so the detail can scroll to the right section. nil = open at the top.
    @State private var deepLinkBookingStep: String?
    /// A conversation surfaced by a tapped message push (`/messages/thread/{id}`),
    /// presented over the shell. nil when nothing is being deep-linked.
    @State private var deepLinkThread: MessageThread?
    /// The activity feed surfaced by a `/client/activity` push, presented over the
    /// shell. Mirrors HomeView's own notifications sheet.
    @State private var showActivity = false
    /// The priority-offers screen surfaced by a `/client/offers` push, presented
    /// over the shell. Carries the `?accept=` recipient id to float + highlight.
    @State private var offersPresentation: OffersPresentation?

    /// Identifiable wrapper so `.sheet(item:)` can carry the optional highlight id.
    private struct OffersPresentation: Identifiable {
        let id = UUID()
        let highlight: String?
    }

    var body: some View {
        TabView(selection: $tab) {
            HomeView(onOpenInbox: { tab = .inbox })
                .tag(ClientTab.ID.home)

            DiscoverView()
                .tag(ClientTab.ID.discover)

            LooksView()
                .tag(ClientTab.ID.looks)

            InboxView()
                .tag(ClientTab.ID.inbox)

            MeView()
                .tag(ClientTab.ID.me)
        }
        .toolbar(.hidden, for: .tabBar)         // hide the system tab bar
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TovisTabBar(selected: $tab, messagesBadge: messagesBadge)
        }
        .tint(BrandColor.accent)
        // Keep the Inbox tab badge live (foreground/Realtime + gentle poll).
        .task { await refreshBadge() }
        .onChange(of: session.refreshTick) { Task { await refreshBadge() } }
        .task { await pollBadge() }
        // Push deep-link routing. `.task` catches a link set before this mounted
        // (cold-launch tap); `.onChange` catches taps while the app is running.
        .task { await routeDeepLink(session.pushDeepLink) }
        .onChange(of: session.pushDeepLink) { _, link in
            Task { await routeDeepLink(link) }
        }
        .sheet(item: $deepLinkBooking) { booking in
            NavigationStack {
                BookingDetailView(booking: booking, onDecision: { session.signalRefresh() }, focusStep: deepLinkBookingStep)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { deepLinkBooking = nil }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        .sheet(item: $deepLinkThread) { thread in
            NavigationStack {
                ThreadView(thread: thread)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { deepLinkThread = nil }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        // NotificationsView brings its own NavigationStack + Done button (same as
        // HomeView's notifications sheet) — present it bare.
        .sheet(isPresented: $showActivity) { NotificationsView() }
        // PriorityOffersView owns no stack (it's also pushed from Home), so wrap it
        // in one + a Done button when presenting from a push, like the booking sheet.
        .sheet(item: $offersPresentation) { presentation in
            NavigationStack {
                PriorityOffersView(highlightRecipientId: presentation.highlight)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { offersPresentation = nil }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
    }

    /// Resolve a push deep link to a concrete destination and present it, then
    /// clear it from the session so it isn't re-handled. Booking ids are resolved
    /// from the bookings list (the same source the in-app center uses — there's no
    /// standalone GET /bookings/[id]).
    private func routeDeepLink(_ link: PushDeepLink?) async {
        guard let link else { return }
        // A pro-shell target arrived while acting as client (a pro who was in their
        // client workspace). Switch workspaces and leave the link buffered — the
        // pro shell's `.task` consumes it once RootView swaps it in. If the switch
        // doesn't take (not entitled), clear it so no stale link sticks.
        if let role = link.role, role != session.activeRole {
            await session.switchWorkspace(to: role)
            if session.activeRole != role { session.clearPushDeepLink() }
            return
        }
        switch link.target {
        case let .booking(id, step):
            // Carry the `step` so the detail scrolls to that section (consult /
            // aftercare); unknown steps just open at the top.
            if let buckets = try? await session.client.bookings.fetch() {
                let all = buckets.upcoming + buckets.pending + buckets.prebooked + buckets.past
                deepLinkBookingStep = step
                deepLinkBooking = all.first { $0.id == id }
            }
        case let .thread(id):
            deepLinkThread = try? await session.client.messages.thread(id: id)
        case .look:
            // No native single-look detail yet — land on the Looks feed.
            tab = .looks
        case let .offers(accept):
            // The full priority-offers + waitlist-offers screen (countdown claim/
            // pass + pro-proposed-time confirm/decline). `accept` floats + highlights
            // the offer the push was about.
            offersPresentation = OffersPresentation(highlight: accept)
        case .referrals:
            // Referrals live under the Me tab.
            tab = .me
        case .activity:
            showActivity = true
        case .clientHome:
            tab = .home
        // Pro-shell targets are handled by the workspace switch above; unreachable
        // here, but the switch must stay exhaustive.
        case .proBooking, .proReviews, .membership, .proProfile, .proCalendar, .proHome:
            break
        }
        session.clearPushDeepLink()
    }

    private func pollBadge() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { await refreshBadge() }
        }
    }

    private func refreshBadge() async {
        let count = (try? await session.client.messages.unreadCount()) ?? 0
        messagesBadge = count <= 0 ? nil : (count > 9 ? "9+" : "\(count)")
    }
}