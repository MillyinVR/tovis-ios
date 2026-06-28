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

struct MainTabView: View {
    @State private var tab: ClientTab.ID = .home

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tag(ClientTab.ID.home)

            ComingSoonView.discover
                .tag(ClientTab.ID.discover)

            ComingSoonView.looks
                .tag(ClientTab.ID.looks)

            ComingSoonView.inbox
                .tag(ClientTab.ID.inbox)

            MeView()
                .tag(ClientTab.ID.me)
        }
        .toolbar(.hidden, for: .tabBar)         // hide the system tab bar
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TovisTabBar(selected: $tab)         // our branded footer
        }
        .tint(BrandColor.accent)
    }
}