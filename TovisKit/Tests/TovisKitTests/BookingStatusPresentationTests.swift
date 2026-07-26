import XCTest
@testable import TovisKit

/// B10 — one word per lifecycle state, the same word web shows.
///
/// The client screens rendered `status.capitalized` straight off the wire.
/// Measured with a real `swift` run rather than assumed: `"IN_PROGRESS"
/// .capitalized` is `"In_Progress"` and `"NO_SHOW".capitalized` is `"No_Show"`,
/// so those two tests below are the exact strings a client used to read in
/// their own app. Prod had two live IN_PROGRESS bookings the day this landed.
final class BookingStatusPresentationTests: XCTestCase {

    private let allStatuses = [
        "PENDING", "ACCEPTED", "IN_PROGRESS", "COMPLETED", "CANCELLED", "NO_SHOW",
    ]

    func testEveryStatusGetsTheCanonicalWord() {
        XCTAssertEqual(BookingStatusPresentation.label("PENDING"), "Pending")
        // Tori's call 2026-07-26: ACCEPTED reads "Confirmed" on every surface,
        // both platforms. The pro LIST takes this word from the server, the pro
        // DETAIL computed its own — and they disagreed.
        XCTAssertEqual(BookingStatusPresentation.label("ACCEPTED"), "Confirmed")
        XCTAssertEqual(BookingStatusPresentation.label("IN_PROGRESS"), "In progress")
        XCTAssertEqual(BookingStatusPresentation.label("COMPLETED"), "Completed")
        XCTAssertEqual(BookingStatusPresentation.label("CANCELLED"), "Cancelled")
        XCTAssertEqual(BookingStatusPresentation.label("NO_SHOW"), "No-show")
    }

    func testNoStatusEverRendersAsAnEnum() {
        for status in allStatuses {
            let label = BookingStatusPresentation.label(status)
            XCTAssertFalse(label.contains("_"), "\(status) leaked an underscore: \(label)")
            XCTAssertNotEqual(label, status)
        }
    }

    func testTheOldCapitalizedRenderingIsWhatThisReplaces() {
        // Pins the defect itself, so nobody "simplifies" this back to
        // `.capitalized` believing it was equivalent.
        XCTAssertEqual("IN_PROGRESS".capitalized, "In_Progress")
        XCTAssertEqual("NO_SHOW".capitalized, "No_Show")
        XCTAssertNotEqual(BookingStatusPresentation.label("IN_PROGRESS"), "In_Progress")
        XCTAssertNotEqual(BookingStatusPresentation.label("NO_SHOW"), "No_Show")
    }

    func testUnknownWireValuesAreHumanizedNotPassedThrough() {
        XCTAssertEqual(BookingStatusPresentation.label("SOMETHING_ELSE"), "Something else")
        XCTAssertEqual(BookingStatusPresentation.label(" accepted "), "Confirmed")
        XCTAssertEqual(BookingStatusPresentation.label(nil), "")
    }

    func testToneSeparatesALiveSessionAndAMissFromTheRest() {
        // Both used to miss every arm of the app's `statusTone` and render in
        // `textMuted` — the same grey as the pro's own blocked time.
        XCTAssertEqual(BookingStatusPresentation.tone("IN_PROGRESS"), .active)
        XCTAssertEqual(BookingStatusPresentation.tone("NO_SHOW"), .ended)
        XCTAssertEqual(BookingStatusPresentation.tone("ACCEPTED"), .active)
        XCTAssertEqual(BookingStatusPresentation.tone("PENDING"), .pending)
        XCTAssertEqual(BookingStatusPresentation.tone("COMPLETED"), .done)
        XCTAssertEqual(BookingStatusPresentation.tone("CANCELLED"), .ended)
        XCTAssertEqual(BookingStatusPresentation.tone("WHAT"), .unknown)
    }

    func testHoldStaysOutOfTheBookingTable() {
        // `HELD` is calendar occupancy, not a booking state. Folding it in here
        // would have quietly dropped B5's gold hold tint, since the app's
        // `statusTone` keeps that arm and delegates the rest.
        XCTAssertEqual(BookingStatusPresentation.tone("HELD"), .unknown)
    }

    /// The pro DETAIL screen kept a private table of its own, which is how it
    /// came to say "Confirmed" while the pro LIST — whose `statusLabel` is
    /// computed server-side by web's table — said "Accepted" for one booking.
    func testProDetailLabelUsesTheSameTable() throws {
        for status in allStatuses {
            let json = """
            {"booking":{"id":"bk_1","status":"\(status)",
            "scheduledFor":"2026-08-01T17:00:00.000Z","endsAt":"2026-08-01T18:00:00.000Z",
            "locationType":"SALON","bufferMinutes":0,"durationMinutes":60,
            "totalDurationMinutes":60,"serviceItems":[],
            "client":{"fullName":"Jane Doe"}}}
            """
            let detail = try JSONDecoder()
                .decode(ProBookingDetailResponse.self, from: Data(json.utf8))
                .booking

            XCTAssertEqual(detail.statusLabel, BookingStatusPresentation.label(status))
        }
    }
}
