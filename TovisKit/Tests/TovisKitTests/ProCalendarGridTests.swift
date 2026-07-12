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

    // ── Day/Week time-grid layout ──

    @Test func eventDayMinutesPositionsWithinDay() {
        // 10:00–11:30 PT on 2026-07-15.
        let layout = ProCalendarGrid.eventDayMinutes(
            startISO: "2026-07-15T17:00:00.000Z", // 10:00 PDT
            endISO: "2026-07-15T18:30:00.000Z",   // 11:30 PDT
            durationMinutes: 90,
            dayYmd: "2026-07-15",
            timeZone: zone,
            stepMinutes: 15)
        #expect(layout?.start == 600)  // 10 * 60
        #expect(layout?.end == 690)    // 11.5 * 60
    }

    @Test func eventDayMinutesEnforcesMinimumHeight() {
        // Zero-ish duration still gets at least one step of height.
        let layout = ProCalendarGrid.eventDayMinutes(
            startISO: "2026-07-15T17:00:00.000Z",
            endISO: "2026-07-15T17:00:00.000Z",
            durationMinutes: 0,
            dayYmd: "2026-07-15",
            timeZone: zone,
            stepMinutes: 15)
        #expect(layout?.start == 600)
        #expect((layout?.end ?? 0) - (layout?.start ?? 0) >= 15)
    }

    @Test func eventDayMinutesClampsSpilloverDays() {
        // An event starting the day before this cell renders from midnight.
        let layout = ProCalendarGrid.eventDayMinutes(
            startISO: "2026-07-14T22:00:00.000Z",
            endISO: "2026-07-15T17:30:00.000Z", // ends 10:30 PDT on the 15th
            durationMinutes: 90,
            dayYmd: "2026-07-15",
            timeZone: zone,
            stepMinutes: 15)
        #expect(layout?.start == 0)
        #expect(layout?.end == 630) // 10:30
    }

    @Test func snapRoundsToStep() {
        #expect(ProCalendarGrid.snap(607, step: 15) == 600)
        #expect(ProCalendarGrid.snap(608, step: 15) == 615)
        #expect(ProCalendarGrid.minutesSinceMidnight(noon(2026, 7, 15), zone) == 720)
    }

    // ── Passive double-book highlight ──

    @Test func overlappingIntervalIdsFlagsOnlyTrueOverlaps() {
        // a 10:00–11:00, b 10:30–11:30 (overlap), c 12:00–13:00 (clear).
        let ids = ProCalendarGrid.overlappingIntervalIds([
            (id: "a", start: 600, end: 660),
            (id: "b", start: 630, end: 690),
            (id: "c", start: 720, end: 780),
        ])
        #expect(ids == ["a", "b"])
    }

    @Test func adjacentIntervalsDoNotOverlap() {
        // Back-to-back (11:00 end == 11:00 start) is NOT a conflict.
        let ids = ProCalendarGrid.overlappingIntervalIds([
            (id: "a", start: 600, end: 660),
            (id: "b", start: 660, end: 720),
        ])
        #expect(ids.isEmpty)
    }

    @Test func overlappingIntervalIdsHandlesNoneAndTriples() {
        #expect(ProCalendarGrid.overlappingIntervalIds([]).isEmpty)
        // Three mutually overlapping intervals all flag.
        let ids = ProCalendarGrid.overlappingIntervalIds([
            (id: "a", start: 600, end: 720),
            (id: "b", start: 630, end: 700),
            (id: "c", start: 690, end: 760),
        ])
        #expect(ids == ["a", "b", "c"])
    }
}
