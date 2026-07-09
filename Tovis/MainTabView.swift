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
    /// A conversation surfaced by a tapped message push (`/messages/thread/{id}`),
    /// presented over the shell. nil when nothing is being deep-linked.
    @State private var deepLinkThread: MessageThread?

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
                BookingDetailView(booking: booking, onDecision: { session.signalRefresh() })
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
    }

    /// Resolve a push deep link to a concrete destination and present it, then
    /// clear it from the session so it isn't re-handled. Booking ids are resolved
    /// from the bookings list (the same source the in-app center uses — there's no
    /// standalone GET /bookings/[id]).
    private func routeDeepLink(_ link: PushDeepLink?) async {
        guard let link else { return }
        switch link.target {
        case let .booking(id):
            if let buckets = try? await session.client.bookings.fetch() {
                let all = buckets.upcoming + buckets.pending + buckets.prebooked + buckets.past
                deepLinkBooking = all.first { $0.id == id }
            }
        case let .thread(id):
            deepLinkThread = try? await session.client.messages.thread(id: id)
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