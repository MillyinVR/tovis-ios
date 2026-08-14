import XCTest
@testable import TovisKit

/// The "your looks, remixed" timestamp. Pinned against web's
/// `formatRelativeDayAgo` (`lib/time/relativeTime.ts`), whose own tests use the
/// same instants.
final class RelativeDayAgoTests: XCTestCase {

    private let ny = TimeZone(identifier: "America/New_York")!

    private func instant(_ iso: String) -> Date {
        guard let date = Wire.date(iso) else {
            XCTFail("unparseable fixture instant \(iso)")
            return Date()
        }
        return date
    }

    func testBucketsByDayThenWeekThenACalendarDate() {
        // 2026-03-15T12:00:00Z is 08:00 on Mar 15 in New York.
        let now = instant("2026-03-15T12:00:00.000Z")

        XCTAssertEqual(
            RelativeDayAgo.label("2026-03-15T05:30:00.000Z", now: now, timeZone: ny), "today")
        XCTAssertEqual(
            RelativeDayAgo.label("2026-03-14T18:00:00.000Z", now: now, timeZone: ny), "yesterday")
        XCTAssertEqual(
            RelativeDayAgo.label("2026-03-12T18:00:00.000Z", now: now, timeZone: ny), "3d ago")
        XCTAssertEqual(
            RelativeDayAgo.label("2026-03-01T18:00:00.000Z", now: now, timeZone: ny), "2w ago")
    }

    func testYesterdayIsACalendarClaimNotAnElapsedHourCount() {
        // 00:10 on Mar 10 in New York — 20 minutes after 23:50 the night before,
        // which an elapsed-time bucket (ActivityTimeAgo) would still call "today".
        let now = instant("2026-03-10T04:10:00.000Z")

        XCTAssertEqual(
            RelativeDayAgo.label("2026-03-10T03:50:00.000Z", now: now, timeZone: ny), "yesterday")
        XCTAssertEqual(
            ActivityTimeAgo.label(for: "2026-03-10T03:50:00.000Z", now: now), "20m ago")
    }

    func testTheOlderThanFallbackRendersInTheGivenZone() {
        let now = instant("2026-03-15T12:00:00.000Z")

        // 02:00Z on Feb 1 is still 21:00 on Jan 31 in New York.
        XCTAssertEqual(
            RelativeDayAgo.label("2026-02-01T02:00:00.000Z", now: now, timeZone: ny), "Jan 31")
        XCTAssertEqual(
            RelativeDayAgo.label(
                "2026-02-01T02:00:00.000Z", now: now, timeZone: TimeZone(identifier: "UTC")!
            ),
            "Feb 1"
        )
    }

    func testAFutureInstantClampsToTodayAndGarbageRendersNothing() {
        let now = instant("2026-03-15T12:00:00.000Z")

        XCTAssertEqual(
            RelativeDayAgo.label("2026-03-20T12:00:00.000Z", now: now, timeZone: ny), "today")
        XCTAssertEqual(RelativeDayAgo.label("not-a-date", now: now, timeZone: ny), "")
    }
}
