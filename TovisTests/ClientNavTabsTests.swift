import Testing

@testable import Tovis

/// The client footer is a 1:1 port of the web's `CLIENT_TABS`
/// (tovis-app `app/config/clientNav.ts`), and it silently drifted: web added a
/// Bookings tab, iOS did not.
///
/// That drift was not cosmetic. `AppointmentsView` is the only surface listing a
/// client's PENDING bookings, and the two data-driven routes to it both exclude
/// PENDING server-side — the home Upcoming card needs an ACCEPTED/IN_PROGRESS
/// booking, and Me → History filters to ACCEPTED/IN_PROGRESS/COMPLETED. With no
/// tab, a client whose only booking was still awaiting their pro's approval fell
/// through to the home card's "No approved bookings yet" empty state, which is
/// text with no link: they could not open, or cancel, their own request.
///
/// So this pins the list itself. A tab quietly dropped here is a client losing
/// the door to their own appointments, and nothing else in the project fails.
@Suite struct ClientNavTabsTests {
    /// Order and identity, matching web CLIENT_TABS exactly.
    @Test func matchesTheWebTabOrder() {
        #expect(ClientNav.tabs.map(\.id) == [.home, .discover, .looks, .bookings, .inbox, .me])
    }

    /// The regression this suite exists for. Named on its own so a failure says
    /// which tab went missing rather than just "the array changed".
    @Test func alwaysOffersBookings() {
        let bookings = ClientNav.tabs.first { $0.id == .bookings }
        #expect(bookings != nil)
        #expect(bookings?.label == "Bookings")
        // Nothing may make this tab conditional: it is the unconditional route to
        // a client's own appointments, pending ones included.
        #expect(bookings?.center == false)
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
