import Foundation
import Testing
@testable import TovisKit

/// `DayGrouping` replaced a helper that was hand-copied into both notification
/// screens. The copies were `private` inside SwiftUI views in the *app* target,
/// so `swift test` can never have reached them directly — the way to prove the
/// consolidation is behaviour-preserving is therefore to transcribe the shipped
/// implementation verbatim here and diff the two across a spread of inputs.
///
/// The transcription below is the code as it stood at `NotificationsView.swift:300`
/// and `ProNotificationsView.swift:293` (identical apart from the element type).
/// If a future change to `DayGrouping` is *meant* to change output, these tests
/// are the ones that must be deliberately updated — that is the point of them.
@Suite("DayGrouping")
struct DayGroupingTests {

    private struct Stub {
        let id: Int
        let createdAt: Date
    }

    // MARK: - The oracle: the pre-consolidation implementation, verbatim

    private struct LegacyDayGroup {
        let key: String
        let items: [Stub]
    }

    private func legacyGroupedByDay(_ list: [Stub]) -> [LegacyDayGroup] {
        let cal = Calendar.current
        var order: [String] = []
        var byDay: [String: [Stub]] = [:]
        let keyFmt = DateFormatter()
        keyFmt.locale = Locale(identifier: "en_US_POSIX")
        keyFmt.dateFormat = "yyyy-MM-dd"
        for n in list {
            let day = n.createdAt
            let key = keyFmt.string(from: cal.startOfDay(for: day))
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(n)
        }
        return order.map { LegacyDayGroup(key: $0, items: byDay[$0] ?? []) }
    }

    private func legacyDayHeading(_ key: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: key) else { return key }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US")
        out.dateFormat = "EEE, MMM d"
        return out.string(from: date)
    }

    // MARK: - Differential: new == old

    /// A spread that covers the shapes a real feed produces: several items on one
    /// day, days out of order, a month boundary, a year boundary, and a day either
    /// side of a US DST transition (2026-03-08, when 2am local does not exist).
    private var spread: [Stub] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let stamps = [
            "2026-07-19T18:30:00Z", "2026-07-19T02:10:00Z", "2026-07-19T23:59:00Z",
            "2026-07-18T00:00:01Z",
            "2026-07-20T12:00:00Z",   // out of order relative to the ones above
            "2026-08-01T06:00:00Z", "2026-07-31T23:00:00Z",   // month boundary
            "2026-01-01T00:30:00Z", "2025-12-31T21:00:00Z",   // year boundary
            "2026-03-08T09:00:00Z", "2026-03-08T18:00:00Z",   // US DST spring-forward
            "2026-03-07T20:00:00Z",
            "2026-11-01T08:30:00Z",   // US DST fall-back
        ]
        return stamps.enumerated().compactMap { index, s in
            iso.date(from: s).map { Stub(id: index, createdAt: $0) }
        }
    }

    @Test("groups identically to the implementation it replaced")
    func matchesLegacyGrouping() {
        let items = spread
        #expect(items.count == 13)  // guards the fixture itself against a typo'd stamp

        let old = legacyGroupedByDay(items)
        let new = DayGrouping.byDay(items) { $0.createdAt }

        #expect(new.map(\.key) == old.map(\.key))
        #expect(new.map { $0.items.map(\.id) } == old.map { $0.items.map(\.id) })
    }

    @Test("titles days identically to the implementation it replaced")
    func matchesLegacyHeadings() {
        let old = legacyGroupedByDay(spread)
        let new = DayGrouping.byDay(spread) { $0.createdAt }

        for (oldGroup, newGroup) in zip(old, new) {
            #expect(DayGrouping.heading(for: newGroup.day) == legacyDayHeading(oldGroup.key))
        }
    }

    @Test("empty in, empty out")
    func emptyList() {
        #expect(DayGrouping.byDay([Stub]()) { $0.createdAt }.isEmpty)
        #expect(legacyGroupedByDay([]).isEmpty)
    }

    // MARK: - Pinned behaviour (zone-independent, so CI can't drift)

    private var losAngeles: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        return cal
    }

    private func date(_ iso8601: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso8601) ?? .distantPast
    }

    @Test("buckets on the calendar's local day, not UTC")
    func bucketsLocally() {
        // 2026-07-20T02:00Z is still the 19th at 7pm in Los Angeles. Grouping by
        // UTC would split these two into different sections; grouping locally —
        // which is what the screens want — keeps them together.
        let evening = Stub(id: 1, createdAt: date("2026-07-20T02:00:00Z"))
        let earlier = Stub(id: 2, createdAt: date("2026-07-19T17:00:00Z"))

        let groups = DayGrouping.byDay([evening, earlier], calendar: losAngeles) { $0.createdAt }

        #expect(groups.count == 1)
        #expect(groups.first?.key == "2026-07-19")
        #expect(groups.first?.items.map(\.id) == [1, 2])
    }

    @Test("preserves first-seen day order, not chronological order")
    func preservesSourceOrder() {
        let items = [
            Stub(id: 1, createdAt: date("2026-07-19T18:00:00Z")),
            Stub(id: 2, createdAt: date("2026-07-21T18:00:00Z")),  // newer, but second
            Stub(id: 3, createdAt: date("2026-07-19T19:00:00Z")),
        ]

        let groups = DayGrouping.byDay(items, calendar: losAngeles) { $0.createdAt }

        #expect(groups.map(\.key) == ["2026-07-19", "2026-07-21"])
        #expect(groups.first?.items.map(\.id) == [1, 3])
    }

    @Test("survives the spring-forward day")
    func springForward() {
        // 2026-03-08 loses 2am in Los Angeles; startOfDay must still land on the
        // 8th rather than skidding into the 7th or 9th.
        let groups = DayGrouping.byDay(
            [Stub(id: 1, createdAt: date("2026-03-08T20:00:00Z"))],
            calendar: losAngeles
        ) { $0.createdAt }

        #expect(groups.first?.key == "2026-03-08")
    }

    @Test("pads month and day to two digits")
    func zeroPadding() {
        let groups = DayGrouping.byDay(
            [Stub(id: 1, createdAt: date("2026-01-05T20:00:00Z"))],
            calendar: losAngeles
        ) { $0.createdAt }

        #expect(groups.first?.key == "2026-01-05")
    }

    @Test("Today / Yesterday / EEE, MMM d")
    func headings() {
        let cal = losAngeles
        let today = date("2026-07-19T20:00:00Z")          // Jul 19 1pm in LA

        #expect(DayGrouping.heading(for: cal.startOfDay(for: today), calendar: cal, now: today) == "Today")

        let yesterday = date("2026-07-18T20:00:00Z")
        #expect(DayGrouping.heading(for: cal.startOfDay(for: yesterday), calendar: cal, now: today) == "Yesterday")

        let older = date("2026-07-15T20:00:00Z")          // a Wednesday
        #expect(DayGrouping.heading(for: cal.startOfDay(for: older), calendar: cal, now: today) == "Wed, Jul 15")
    }

    @Test("headings are not localized away from web's wording")
    func headingLocaleIsPinned() {
        // The label mirrors web's copy, so it stays en_US regardless of device
        // locale — the same reason the formatter pins its locale explicitly.
        let cal = losAngeles
        let now = date("2026-07-19T20:00:00Z")
        let december = date("2026-12-25T20:00:00Z")

        #expect(DayGrouping.heading(for: cal.startOfDay(for: december), calendar: cal, now: now) == "Fri, Dec 25")
    }
}
