// The signed-in shell: a tab bar over the client surfaces.
// Home + Appointments today; more tabs (discover, messages, profile) land here
// as those screens get built.
import SwiftUI

struct MainTabView: View {
    enum Tab: Hashable { case home, appointments }

    @State private var tab: Tab = .home

    var body: some View {
        TabView(selection: $tab) {
            HomeView(onOpenAppointments: { tab = .appointments })
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            AppointmentsView()
                .tabItem { Label("Appointments", systemImage: "calendar") }
                .tag(Tab.appointments)
        }
        .tint(BrandColor.accent)
    }
}
