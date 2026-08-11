import Testing

@testable import Tovis

/// The client footer is a 1:1 port of the web's `CLIENT_TABS`
/// (tovis-app `app/config/clientNav.ts`), and it has drifted from it before —
/// web added a Bookings tab, iOS did not — so the list is pinned here.
///
/// Bookings has since left the footer on BOTH platforms: it lives in the home
/// area. That drop is safe only because the constraint moved with it.
/// `AppointmentsView` is the only surface listing a client's PENDING bookings,
/// and the two data-driven routes to it both exclude PENDING server-side — the
/// home Upcoming card is fed an ACCEPTED/IN_PROGRESS booking, and Me → History
/// filters to ACCEPTED/IN_PROGRESS/COMPLETED. So a client whose only booking is
/// still awaiting their pro's approval lands on the home card's "No approved
/// bookings yet" empty state, and `HomeView.UpcomingCard` therefore pushes
/// `AppointmentsView` from that empty state as well as the populated one.
///
/// Read together: this suite pins the tab list, and that unconditional push is
/// what keeps a client able to open — and cancel — their own request. A tab
/// quietly re-added or dropped here is a client's door moving, and nothing else
/// in the project fails.
@Suite struct ClientNavTabsTests {
    /// Order and identity, matching web CLIENT_TABS exactly.
    @Test func matchesTheWebTabOrder() {
        #expect(ClientNav.tabs.map(\.id) == [.home, .discover, .looks, .inbox, .me])
    }

    /// The footer deliberately carries no bookings tab. Named on its own so a
    /// failure says the bar regrew a door rather than just "the array changed" —
    /// and so re-adding one is a decision, taken with the home-card route in view
    /// rather than by accident.
    @Test func carriesNoBookingsTab() {
        #expect(ClientNav.tabs.allSatisfy { $0.label.lowercased() != "bookings" })
        #expect(ClientNav.tabs.count == 5)
    }

    /// `TovisTabBar` reserves an empty slot for the centre mark and draws the
    /// real button in an overlay positioned on THAT slot. Two centre tabs would
    /// draw two marks over one slot; zero would leave the feather unreachable.
    @Test func hasExactlyOneCenterTab() {
        #expect(ClientNav.tabs.filter(\.center).count == 1)
        #expect(ClientNav.tabs.first(where: \.center)?.id == .looks)
    }

    /// The Inbox badge is the only badge, on web and here — the footer owning the
    /// unread-messages signal is why the client home header carries just one bell.
    @Test func onlyInboxCarriesABadge() {
        #expect(ClientNav.tabs.filter(\.hasBadge).map(\.id) == [.inbox])
    }
}
