import Foundation
import Testing
@testable import TovisKit

// `Wire` spent its whole life in the app target (`Tovis/Theme/Formatters.swift`),
// where `swift test` could not reach it — so the formatters every list row and
// every money label depend on had NO tests at all. Moving it into TovisKit is
// only worth doing if that changes, which is what this file is for.
//
// These are characterization tests: they pin the behaviour as it shipped, so the
// move is provably a move.

@Suite("Wire formatting")
struct WireTests {
    private let zone = "America/Los_Angeles"

    // MARK: - ISO parsing

    @Test("Parses backend instants with AND without fractional seconds")
    func parsesBothIsoShapes() {
        // The server sends both shapes; falling back to the plain reader is the
        // reason there are two formatters rather than one.
        let withFraction = Wire.date("2026-07-18T17:09:30.000Z")
        let plain = Wire.date("2026-07-18T17:09:30Z")
        #expect(withFraction != nil)
        #expect(plain != nil)
        #expect(withFraction == plain)
    }

    @Test("An unparseable instant yields nil, and the formatters yield empty")
    func unparseableIsEmpty() {
        #expect(Wire.date("not-a-date") == nil)
        // Every display formatter degrades to "" rather than crashing or
        // rendering a placeholder date.
        #expect(Wire.dateTime("not-a-date", timeZone: zone) == "")
        #expect(Wire.dateOnly("not-a-date") == "")
        #expect(Wire.monthDay("not-a-date") == "")
        #expect(Wire.relativeAgo("not-a-date") == "")
    }

    // MARK: - Timezone resolution at the edge

    @Test("Instants render in the SUPPLIED zone, not the device's")
    func rendersInSuppliedZone() {
        // 2026-07-18T02:30:00Z is the 17th at 7:30pm in Los Angeles — the
        // day-boundary case, which is exactly what a UTC-defaulted formatter
        // gets wrong (the whole reason this type exists).
        let iso = "2026-07-18T02:30:00Z"
        #expect(Wire.dateTime(iso, timeZone: zone) == "Fri, Jul 17 · 7:30 PM")
        #expect(Wire.dateOnly(iso, timeZone: zone) == "Jul 17, 2026")
        #expect(Wire.monthDay(iso, timeZone: zone) == "Jul 17")

        // Same instant, a zone the other side of UTC — still the 18th there.
        #expect(Wire.dateOnly(iso, timeZone: "Europe/London") == "Jul 18, 2026")
    }

    @Test("An unknown zone identifier falls back rather than returning empty")
    func unknownZoneFallsBack() {
        // `TimeZone(identifier:)` returns nil for junk; the formatters fall back
        // to the device zone instead of dropping the value.
        #expect(!Wire.dateOnly("2026-07-18T02:30:00Z", timeZone: "Mars/Olympus").isEmpty)
    }

    // MARK: - Compact relative age

    @Test("Relative age buckets: now, minutes, hours, days, then a date")
    func relativeBuckets() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ seconds: TimeInterval) -> String {
            let then = now.addingTimeInterval(-seconds)
            return Wire.relativeAgo(Wire.nowISOFormatted(then), now: now)
        }
        #expect(ago(0) == "now")
        #expect(ago(59) == "now")
        #expect(ago(60) == "1m")
        #expect(ago(59 * 60) == "59m")
        #expect(ago(60 * 60) == "1h")
        #expect(ago(23 * 3600) == "23h")
        #expect(ago(24 * 3600) == "1d")
        #expect(ago(6 * 86400) == "6d")
        // Past a week it becomes a date, not "7d".
        #expect(!ago(7 * 86400).contains("d"))
    }

    @Test("relativeAgo is the COMPACT formatter — no 'ago' suffix, no week bucket")
    func compactIsDistinctFromActivityFeed() {
        // ⚠️ This is NOT a duplicate of `ActivityTimeAgo`, and the difference is
        // deliberate: web ships two relative formatters off one bucketing core.
        // Round-3 item 15's card called this a drift to reconcile; it is not.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fiveMinutesAgo = now.addingTimeInterval(-300)
        let iso = Wire.nowISOFormatted(fiveMinutesAgo)

        #expect(Wire.relativeAgo(iso, now: now) == "5m")
        #expect(ActivityTimeAgo.label(for: fiveMinutesAgo, now: now) == "5m ago")
    }

    // MARK: - Money

    @Test("Money drops .00 but keeps real cents")
    func moneyFormatting() {
        #expect(Wire.money("120.00") == "$120")
        #expect(Wire.money("45.50") == "$45.50")
        #expect(Wire.money("0.00") == "$0")
        #expect(Wire.money(nil) == nil)
    }

    @Test("Integer cents honour the wire currency code")
    func moneyCents() {
        #expect(Wire.moneyCents(12000) == "$120")
        #expect(Wire.moneyCents(4550) == "$45.50")
        #expect(Wire.moneyCents(nil) == nil)
        // The currency is a wire field, not an assumption.
        #expect(Wire.moneyCents(12000, currency: "eur")?.contains("120") == true)
    }

    @Test("A round-trip through nowISO parses back")
    func nowISORoundTrips() {
        #expect(Wire.date(Wire.nowISO()) != nil)
    }
}

private extension Wire {
    /// Test helper: the fractional-seconds ISO spelling for an arbitrary date,
    /// so the relative-age buckets can be driven from a fixed `now`.
    static func nowISOFormatted(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
