import Testing
import TovisKit
@testable import Tovis

/// Book the Look, B8 — the receipt says what the SERVER actually did.
///
/// Found by driving the flow, not by reading the diff: the confirmation screen
/// told everyone "Request sent · PENDING CONFIRMATION", including a client of an
/// auto-accepting pro whose booking came back ACCEPTED. That is the same lie the
/// proposal's server-composed `commitNote` exists to prevent, printed one screen
/// later — and book-the-look makes auto-accept a first-class mode (decision 4),
/// so it is now reachable by design rather than by accident.
@Suite struct BookingReceiptStatusTests {
    @Test func anAcceptedBookingIsReportedAsConfirmedNotAsAWait() {
        // The canonical helper, not a second fork: ACCEPTED reads "Confirmed".
        #expect(BookingStatusPresentation.tone("ACCEPTED") == .active)

        let steps = BookingFlowView.successSteps(proName: "Noor", confirmed: true)
        #expect(steps.count == 3)
        let text = steps.map(\.text).joined(separator: " ")
        // 🔴 None of the request-mode promises may survive: they are all about a
        // confirmation that has already happened.
        #expect(!text.contains("reviews within"))
        #expect(!text.contains("the moment they confirm"))
        #expect(!text.contains("No charge until"))
        #expect(text.contains("Noor"))
    }

    @Test func aPendingBookingKeepsTheRequestModePromises() {
        #expect(BookingStatusPresentation.tone("PENDING") == .pending)

        let steps = BookingFlowView.successSteps(proName: "Noor", confirmed: false)
        let text = steps.map(\.text).joined(separator: " ")
        #expect(text.contains("reviews within a few hours"))
        #expect(text.contains("No charge until they confirm"))
    }

    /// An unknown status is NOT treated as confirmed. The receipt's confirmed
    /// branch is opt-in on an explicitly active status, so a server that grows a
    /// new state degrades to the cautious wording rather than promising a
    /// confirmation nobody made.
    @Test func anUnknownStatusIsNotReportedAsConfirmed() {
        #expect(BookingStatusPresentation.tone("SOMETHING_NEW") != .active)
        #expect(BookingStatusPresentation.tone(nil) != .active)
    }
}
