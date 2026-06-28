// The signed-in shell: the custom Tovis footer over the client surfaces.
//
// Matches the web client footer 1:1 — Home · Discover · Looks(center feather) ·
// Inbox · Me (see ClientTab + TovisTabBar). Appointments is NOT a footer tab
// (the web reaches bookings from the home cards and the Me tab, not the footer);
// HomeView pushes to it, and the Me tab links to it.
//
// We keep a real SwiftUI TabView for per-tab state + lazy loading, hide its
// system bar, and overlay our branded bar via safeAreaInset so the raised
// feather can lift above the bar like the web's .tovis-center-lift.
import SwiftUI
import TovisKit

struct MainTabView: View {
    @Environment(SessionModel.self) private var session
    @State private var tab: ClientTab.ID = .home
    @State private var messagesBadge: String?

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