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

    // ── Side-by-side overlap column packing ──

    @Test func overlapColumnLayoutTwoOverlapSplitIntoColumns() {
        // a 10:00–11:00, b 10:30–11:30 overlap → two columns, both count 2.
        let cols = ProCalendarGrid.overlapColumnLayout([
            (id: "a", start: 600, end: 660),
            (id: "b", start: 630, end: 690),
        ])
        #expect(cols["a"]?.column == 0)
        #expect(cols["a"]?.columnCount == 2)
        #expect(cols["b"]?.column == 1)
        #expect(cols["b"]?.columnCount == 2)
    }

    @Test func overlapColumnLayoutDisjointAreFullWidth() {
        // No overlap → each is its own cluster, full width (column 0, count 1).
        let cols = ProCalendarGrid.overlapColumnLayout([
            (id: "a", start: 600, end: 660),
            (id: "b", start: 720, end: 780),
        ])
        #expect(cols["a"]?.column == 0)
        #expect(cols["a"]?.columnCount == 1)
        #expect(cols["b"]?.column == 0)
        #expect(cols["b"]?.columnCount == 1)
    }

    @Test func overlapColumnLayoutBackToBackDoNotShareCluster() {
        // Touching (11:00 end == 11:00 start) is half-open non-overlap → each
        // full-width, so a back-to-back pair stays edge-to-edge, not side-by-side.
        let cols = ProCalendarGrid.overlapColumnLayout([
            (id: "a", start: 600, end: 660),
            (id: "b", start: 660, end: 720),
        ])
        #expect(cols["a"]?.columnCount == 1)
        #expect(cols["b"]?.columnCount == 1)
        #expect(cols["a"]?.column == 0)
        #expect(cols["b"]?.column == 0)
    }

    @Test func overlapColumnLayoutThreeMutualUseThreeColumns() {
        let cols = ProCalendarGrid.overlapColumnLayout([
            (id: "a", start: 600, end: 720),
            (id: "b", start: 630, end: 700),
            (id: "c", start: 690, end: 760),
        ])
        #expect(cols["a"]?.column == 0)
        #expect(cols["b"]?.column == 1)
        #expect(cols["c"]?.column == 2)
        #expect(cols["a"]?.columnCount == 3)
        #expect(cols["b"]?.columnCount == 3)
        #expect(cols["c"]?.columnCount == 3)
    }

    @Test func overlapColumnLayoutReusesAFreedColumn() {
        // Long a spans the cluster; b then c are short and non-overlapping with each
        // other, so c reuses b's column. Peak concurrency is 2 → count 2 for all.
        let cols = ProCalendarGrid.overlapColumnLayout([
            (id: "a", start: 0, end: 100),
            (id: "b", start: 10, end: 20),
            (id: "c", start: 30, end: 40),
        ])
        #expect(cols["a"]?.column == 0)
        #expect(cols["b"]?.column == 1)
        #expect(cols["c"]?.column == 1) // reuses b's freed column
        #expect(cols["a"]?.columnCount == 2)
        #expect(cols["b"]?.columnCount == 2)
        #expect(cols["c"]?.columnCount == 2)
    }

    @Test func overlapColumnLayoutSeparateClustersCountIndependently() {
        // Cluster 1 (a,b) overlaps → count 2; cluster 2 (c) is alone → count 1.
        let cols = ProCalendarGrid.overlapColumnLayout([
            (id: "a", start: 600, end: 660),
            (id: "b", start: 630, end: 690),
            (id: "c", start: 800, end: 860),
        ])
        #expect(cols["a"]?.columnCount == 2)
        #expect(cols["b"]?.columnCount == 2)
        #expect(cols["c"]?.columnCount == 1)
        #expect(cols["c"]?.column == 0)
    }

    @Test func overlapColumnLayoutEmptyIsEmpty() {
        #expect(ProCalendarGrid.overlapColumnLayout([]).isEmpty)
    }

    @Test func overlapColumnLayoutIsStableRegardlessOfInputOrder() {
        // Shuffled input yields the same column assignment (deterministic sort).
        let forward = ProCalendarGrid.overlapColumnLayout([
            (id: "a", start: 600, end: 720),
            (id: "b", start: 630, end: 700),
            (id: "c", start: 690, end: 760),
        ])
        let shuffled = ProCalendarGrid.overlapColumnLayout([
            (id: "c", start: 690, end: 760),
            (id: "a", start: 600, end: 720),
            (id: "b", start: 630, end: 700),
        ])
        #expect(forward["a"]?.column == shuffled["a"]?.column)
        #expect(forward["b"]?.column == shuffled["b"]?.column)
        #expect(forward["c"]?.column == shuffled["c"]?.column)
    }

    // ── New-booking form passive double-book heads-up ──

    /// 2026-07-15, minutes UTC via a fixed epoch so the tests are TZ-independent.
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        // 2026-07-15T00:00:00Z = 1_784_246_400.
        Date(timeIntervalSince1970: 1_784_246_400 + Double(hour * 3600 + minute * 60))
    }

    @Test func overlappingClientNamesReturnsEveryCollision() {
        // Proposed 17:00–18:00 vs Sam 17:30–18:30 (overlap), Alex 16:30–17:15
        // (overlap), Jordan 19:00–20:00 (clear).
        let names = ProCalendarGrid.overlappingClientNames(
            proposedStart: at(17), proposedEnd: at(18),
            events: [
                (id: "a", clientName: "Sam Rivera", start: at(17, 30), end: at(18, 30)),
                (id: "b", clientName: "Alex Rivera", start: at(16, 30), end: at(17, 15)),
                (id: "c", clientName: "Jordan Lee", start: at(19), end: at(20)),
            ],
            fallbackName: "another appointment")
        #expect(names == ["Sam Rivera", "Alex Rivera"])
    }

    @Test func overlappingClientNamesIgnoresBackToBack() {
        let names = ProCalendarGrid.overlappingClientNames(
            proposedStart: at(17), proposedEnd: at(18),
            events: [(id: "a", clientName: "Sam Rivera", start: at(18), end: at(19))],
            fallbackName: "another appointment")
        #expect(names.isEmpty)
    }

    @Test func overlappingClientNamesFallsBackAndDedupes() {
        #expect(ProCalendarGrid.overlappingClientNames(
            proposedStart: at(17), proposedEnd: at(18),
            events: [], fallbackName: "x").isEmpty)

        // A nameless overlap uses the fallback; a repeated name collapses.
        let names = ProCalendarGrid.overlappingClientNames(
            proposedStart: at(17), proposedEnd: at(18),
            events: [
                (id: "a", clientName: "   ", start: at(17, 10), end: at(17, 40)),
                (id: "b", clientName: "Sam Rivera", start: at(17, 20), end: at(17, 50)),
                (id: "c", clientName: "Sam Rivera", start: at(17, 45), end: at(18, 30)),
            ],
            fallbackName: "another appointment")
        #expect(names == ["another appointment", "Sam Rivera"])
    }
}
