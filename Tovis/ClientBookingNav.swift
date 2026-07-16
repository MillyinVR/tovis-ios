import TovisKit

/// Identifiable + Hashable wrapper so a resolved `ClientBooking` can drive a
/// `navigationDestination(item:)` push into `BookingDetailView`. `ClientBooking`
/// is `Identifiable` but not `Hashable` (its wire nested types aren't), which
/// `navigationDestination(item:)` requires — hence this thin wrapper keyed on the
/// booking id. The client-side counterpart of `MessageThreadNav`, and shared by
/// every surface that resolves a booking id before pushing its detail
/// (AftercareInboxView / PriorityOffersView / ThreadView) — those each carried an
/// identical private copy before.
///
/// Note this is distinct from `ProCalendarView`'s id-only nav wrapper: the pro
/// booking detail fetches from an id (`ProBookingDetailView(bookingId:)`), while
/// the client's takes the whole object, because there is no single-booking client
/// GET (see `BookingsService.booking(id:)`).
struct ClientBookingNav: Identifiable, Hashable {
    let booking: ClientBooking
    var id: String { booking.id }
    static func == (lhs: ClientBookingNav, rhs: ClientBookingNav) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
