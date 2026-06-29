import Foundation
import Testing
@testable import TovisKit

// Pure month-grid + view-range math (no network). Anchored in a fixed zone so
// the assertions are deterministic regardless of where CI runs.
struct ProCalendarGridTests {
    private let zone = TimeZone(identifier: "America/Los_Angeles")!

    /// Build a UTC instant at local noon for a given Y-M-D in `zone`.
    private func noon(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(
            year: year, month: month, day: day, hour: 12))!
    }

    @Test func monthGridIs42MondayStartCells() {
        let cells = ProCalendarGrid.monthCells(
            reference: noon(2026, 7, 15), timeZone: zone, today: noon(2026, 7, 15))

        #expect(cells.count == 42)

        // The grid always starts on a Monday (firstWeekday = 2).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        #expect(cal.component(.weekday, from: cells.first!.startOfDay) == 2)

        // July 2026 has 31 days, so 31 cells fall in the current month.
        #expect(cells.filter(\.isInCurrentMonth).count == 31)

        // The 1st and 31st are in-month; a leading/trailing day is not.
        let first = cells.first { $0.dayYmd == "2026-07-01" }
        #expect(first?.isInCurrentMonth == true)
        #expect(first?.dayNumber == 1)
        #expect(cells.contains { $0.dayYmd == "2026-07-31" && $0.isInCurrentMonth })
        #expect(cells.first!.isInCurrentMonth == false) // grid bleeds into June
    }

    @Test func todayFlagMarksExactlyOneCell() {
        let cells = ProCalendarGrid.monthCells(
            reference: noon(2026, 7, 15), timeZone: zone, today: noon(2026, 7, 9))
        let todays = cells.filter(\.isToday)
        #expect(todays.count == 1)
        #expect(todays.first?.dayYmd == "2026-07-09")
    }

    @Test func headerLabelsPerView() {
        let ref = noon(2026, 7, 15)
        #expect(ProCalendarGrid.headerLabel(view: .month, reference: ref, timeZone: zone)
            == "July 2026")
        #expect(ProCalendarGrid.headerLabel(view: .day, reference: ref, timeZone: zone)
            == "Wed, Jul 15")
        // Mon–Sun week containing Jul 15 (a Wednesday) = Jul 13 – Jul 19.
        #expect(ProCalendarGrid.headerLabel(view: .week, reference: ref, timeZone: zone)
            == "Jul 13 – Jul 19")
    }

    @Test func fetchRangeMatchesView() {
        let ref = noon(2026, 7, 15)

        let day = ProCalendarGrid.fetchRange(view: .day, reference: ref, timeZone: zone)
        #expect(ProCalendarGrid.ymd(day.from, zone) == "2026-07-15")
        #expect(ProCalendarGrid.ymd(day.to, zone) == "2026-07-16")

        let week = ProCalendarGrid.fetchRange(view: .week, reference: ref, timeZone: zone)
        #expect(ProCalendarGrid.ymd(week.from, zone) == "2026-07-13")
        #expect(ProCalendarGrid.ymd(week.to, zone) == "2026-07-20")

        // Month window spans the full 42-cell grid (starts in late June).
        let month = ProCalendarGrid.fetchRange(view: .month, reference: ref, timeZone: zone)
        let cells = ProCalendarGrid.monthCells(reference: ref, timeZone: zone, today: ref)
        #expect(ProCalendarGrid.ymd(month.from, zone) == cells.first!.dayYmd)
    }

    @Test func stepMovesByViewUnit() {
        let ref = noon(2026, 7, 15)
        let nextMonth = ProCalendarGrid.step(view: .month, reference: ref, by: 1, timeZone: zone)
        #expect(ProCalendarGrid.ymd(nextMonth, zone) == "2026-08-15")

        let prevWeek = ProCalendarGrid.step(view: .week, reference: ref, by: -1, timeZone: zone)
        #expect(ProCalendarGrid.ymd(prevWeek, zone) == "2026-07-08")

        let nextDay = ProCalendarGrid.step(view: .day, reference: ref, by: 1, timeZone: zone)
        #expect(ProCalendarGrid.ymd(nextDay, zone) == "2026-07-16")
    }
}
