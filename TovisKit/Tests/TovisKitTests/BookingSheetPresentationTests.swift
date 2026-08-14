import XCTest
@testable import TovisKit

/// Screen 3 — the booking sheet's presentation rules, pinned against the web
/// twin they mirror. Four of these are the PARITY defects the walkthrough found:
/// iOS showed a bare "$30" where prices are starting prices, called a
/// recommended add-on "Popular", and had neither dayparts nor per-day supply.
final class BookingSheetPresentationTests: XCTestCase {

    // MARK: - Dayparts (lib/bookingTime.ts `dayPeriodOfHour`)

    func testDaypartBoundariesMatchWeb() {
        XCTAssertEqual(BookingSheetPresentation.DayPeriod.of(hour: 0), .morning)
        XCTAssertEqual(BookingSheetPresentation.DayPeriod.of(hour: 11), .morning)
        XCTAssertEqual(BookingSheetPresentation.DayPeriod.of(hour: 12), .afternoon)
        XCTAssertEqual(BookingSheetPresentation.DayPeriod.of(hour: 16), .afternoon)
        XCTAssertEqual(BookingSheetPresentation.DayPeriod.of(hour: 17), .evening)
        XCTAssertEqual(BookingSheetPresentation.DayPeriod.of(hour: 23), .evening)
    }

    func testSlotsAreBucketedInTheLocationZoneNotTheDeviceZone() {
        // 2026-03-06T16:30:00Z is 8:30 AM in Los Angeles and 5:30 PM in Berlin —
        // morning or evening depending entirely on whose clock you read it with.
        let slots = ["2026-03-06T16:30:00.000Z"]

        let la = BookingSheetPresentation.groupSlotsByPeriod(
            slots, timeZone: "America/Los_Angeles"
        )
        XCTAssertEqual(la[.morning], slots)
        XCTAssertEqual(la[.evening], [])

        let berlin = BookingSheetPresentation.groupSlotsByPeriod(
            slots, timeZone: "Europe/Berlin"
        )
        XCTAssertEqual(berlin[.evening], slots)
        XCTAssertEqual(berlin[.morning], [])
    }

    func testUnparseableSlotsAreDroppedRatherThanMisfiled() {
        let grouped = BookingSheetPresentation.groupSlotsByPeriod(
            ["not-a-date"], timeZone: "America/Los_Angeles"
        )
        XCTAssertEqual(grouped.values.flatMap { $0 }, [])
    }

    func testOpensOnTheFirstDaypartThatHasTimes() {
        let grouped: [BookingSheetPresentation.DayPeriod: [String]] = [
            .morning: [], .afternoon: ["a"], .evening: ["b"],
        ]
        XCTAssertEqual(
            BookingSheetPresentation.firstNonEmptyPeriod(grouped, preferred: .morning),
            .afternoon
        )
        // A preferred daypart that HAS times is kept, so the tab doesn't jump.
        XCTAssertEqual(
            BookingSheetPresentation.firstNonEmptyPeriod(grouped, preferred: .evening),
            .evening
        )
        // Nothing anywhere → keep the current tab rather than reset it.
        XCTAssertEqual(
            BookingSheetPresentation.firstNonEmptyPeriod(
                [.morning: [], .afternoon: [], .evening: []], preferred: .evening
            ),
            .evening
        )
    }

    // MARK: - Day supply

    func testDaySupplyReadsAsScarcityOnlyWhenItIs() {
        XCTAssertEqual(BookingSheetPresentation.daySupplyLabel(slotCount: 6), "6 open")
        XCTAssertEqual(BookingSheetPresentation.daySupplyLabel(slotCount: 3), "3 open")
        XCTAssertEqual(BookingSheetPresentation.daySupplyLabel(slotCount: 2), "2 left")
        XCTAssertEqual(BookingSheetPresentation.daySupplyLabel(slotCount: 1), "1 left")
        XCTAssertEqual(BookingSheetPresentation.daySupplyLabel(slotCount: 0), "Full")

        XCTAssertFalse(BookingSheetPresentation.daySupplyIsScarce(slotCount: 3))
        XCTAssertTrue(BookingSheetPresentation.daySupplyIsScarce(slotCount: 2))
        // A day with nothing left isn't "scarce" — it's gone. And it never
        // reaches this UI anyway: `/availability/bootstrap` omits zero-slot days.
        XCTAssertFalse(BookingSheetPresentation.daySupplyIsScarce(slotCount: 0))
    }

    // MARK: - Trust chips (lib/booking/trustSignals.ts + SheetCover's TrustRow)

    func testTrustChipsMirrorWebChipForChip() {
        let chips = BookingSheetPresentation.trustChips(
            AvailabilityTrust(
                verified: true,
                completedBookings: 412,
                rating: AvailabilityTrustRating(average: 4.8, count: 96),
                freeCancellationHours: 24
            )
        )

        XCTAssertEqual(chips.map(\.text), ["✓ Verified pro", "412 booked", "Free cancel 24h"])
        XCTAssertEqual(chips.map(\.isAccent), [true, false, false])
    }

    func testAnUnknownSignalIsOmittedRatherThanRenderedAsZero() {
        // A brand-new pro: not verified, no completed bookings, no reviews. The
        // row is not empty — cancelling is still free, which is a real claim.
        let chips = BookingSheetPresentation.trustChips(
            AvailabilityTrust(verified: false)
        )

        XCTAssertEqual(chips.map(\.text), ["Free cancellation"])
        XCTAssertFalse(chips.contains { $0.text.contains("0 booked") })
    }

    func testNoTrustPayloadDrawsNoRowAtAll() {
        // An older server that predates the field sends nothing — which must read
        // as "unknown", not as a pro with no reassurance to offer.
        XCTAssertEqual(BookingSheetPresentation.trustChips(nil), [])
    }

    func testBookedCountUsesTheAppsOneAbbreviationRule() {
        XCTAssertEqual(BookingSheetPresentation.bookedCountLabel(912), "912 booked")
        XCTAssertEqual(BookingSheetPresentation.bookedCountLabel(1200), "1.2K booked")
        XCTAssertEqual(BookingSheetPresentation.bookedCountLabel(0), "0 booked")
    }

    func testRatingRendersToOneDecimalOrNotAtAll() {
        XCTAssertEqual(
            BookingSheetPresentation.ratingLabel(AvailabilityTrustRating(average: 4.75, count: 96)),
            "4.8★"
        )
        XCTAssertEqual(
            BookingSheetPresentation.ratingLabel(AvailabilityTrustRating(average: 5, count: 3)),
            "5.0★"
        )
        XCTAssertNil(BookingSheetPresentation.ratingLabel(nil))
    }

    // MARK: - Prices — Tori's standing rule

    func testAnAddOnPriceIsAlwaysAStartingPrice() {
        XCTAssertEqual(BookingSheetPresentation.addOnPriceLabel("30.00"), "From $30")
        XCTAssertEqual(BookingSheetPresentation.addOnPriceLabel("45.50"), "From $45.50")
        // The defect this replaces: iOS rendered a bare "$30".
        XCTAssertNotEqual(BookingSheetPresentation.addOnPriceLabel("30.00"), "$30")
    }

    func testAnUnusablePriceRendersNothingRatherThanZero() {
        XCTAssertNil(BookingSheetPresentation.addOnPriceLabel(nil))
        XCTAssertNil(BookingSheetPresentation.addOnPriceLabel("not-a-price"))
    }

    // MARK: - Hold countdown

    func testTheSheetCountdownIsMmSsLikeWeb() {
        XCTAssertEqual(BookingSheetPresentation.holdCountdownLabel(secondsRemaining: 298), "04:58")
        XCTAssertEqual(BookingSheetPresentation.holdCountdownLabel(secondsRemaining: 59), "00:59")
        XCTAssertEqual(BookingSheetPresentation.holdCountdownLabel(secondsRemaining: 0), "00:00")
        // A clock that has run past the expiry must not render a negative time.
        XCTAssertEqual(BookingSheetPresentation.holdCountdownLabel(secondsRemaining: -30), "00:00")
    }

    func testUrgencyStartsAtTwoMinutesAndEndsAtExpiry() {
        XCTAssertFalse(BookingSheetPresentation.holdIsUrgent(secondsRemaining: 121))
        XCTAssertTrue(BookingSheetPresentation.holdIsUrgent(secondsRemaining: 120))
        XCTAssertTrue(BookingSheetPresentation.holdIsUrgent(secondsRemaining: 1))
        XCTAssertFalse(BookingSheetPresentation.holdIsUrgent(secondsRemaining: 0))
    }

    func testTheAddOnsStripCountdownMatchesWebsWording() {
        XCTAssertEqual(BookingSheetPresentation.holdStripLabel(secondsRemaining: 300), "Hold: 5m")
        XCTAssertEqual(BookingSheetPresentation.holdStripLabel(secondsRemaining: 61), "Hold: 2m")
        XCTAssertEqual(BookingSheetPresentation.holdStripLabel(secondsRemaining: 45), "Hold: 45s")
        XCTAssertEqual(BookingSheetPresentation.holdStripLabel(secondsRemaining: 0), "Hold expired")
        XCTAssertEqual(BookingSheetPresentation.holdStripLabel(secondsRemaining: -5), "Hold expired")
    }
}
