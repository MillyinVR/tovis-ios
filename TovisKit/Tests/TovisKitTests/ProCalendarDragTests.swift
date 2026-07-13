import Foundation
import Testing
@testable import TovisKit

// Pure drag-to-reschedule drop math (no view, no network) — the logic the native
// day/week grid's long-press drag runs on release (#99/#100). `pxPerMinute` matches
// the grid (1.5 → a 15-min step is 22.5pt); `step` = 15.
struct ProCalendarDragTests {
    private let zone = TimeZone(identifier: "America/Los_Angeles")!
    private let px = 1.5
    private let step = 15

    /// Drop a tile starting at `start` (minutes-since-midnight) after dragging
    /// `points` vertically; `duration` bounds how late it can land.
    private func dropped(from start: Int, drag points: Double, duration: Int = 60) -> Int {
        ProCalendarGrid.draggedStartMinutes(
            originalStartMinutes: start,
            translationPoints: points,
            pxPerMinute: px,
            durationMinutes: duration,
            stepMinutes: step)
    }

    // ── translation → snapped minutes ──

    @Test func dragDownByOneStepMovesOneStep() {
        // 22.5pt at 1.5px/min = 15 min → 10:00 (600) becomes 10:15 (615).
        #expect(dropped(from: 600, drag: 22.5) == 615)
    }

    @Test func dragUpByTwoStepsMovesBack() {
        // -45pt = -30 min → 10:00 → 9:30.
        #expect(dropped(from: 600, drag: -45) == 570)
    }

    @Test func subStepDragSnapsToNearestStep() {
        // ~6.7 min rounds to 0 steps (no move); ~8 min rounds up to one step.
        #expect(dropped(from: 600, drag: 10) == 600)
        #expect(dropped(from: 600, drag: 12) == 615)
    }

    @Test func offGridStartSnapsToTheGrid() {
        // An off-grid original start with no drag still snaps to the 15-min grid.
        #expect(dropped(from: 607, drag: 0) == 600)
    }

    // ── clamping within the day ──

    @Test func clampsAtTopOfDay() {
        // Dragging far up can't cross midnight.
        #expect(dropped(from: 60, drag: -10_000) == 0)
    }

    @Test func clampsSoDurationFitsBeforeMidnight() {
        // A 90-min booking dragged past the end clamps so it still ends by 24:00:
        // maxStart = 1440 - 90 = 1350 (22:30).
        #expect(dropped(from: 1300, drag: 10_000, duration: 90) == 1350)
        // A 60-min booking clamps to 1380 (23:00) under the same huge drag.
        #expect(dropped(from: 1300, drag: 10_000, duration: 60) == 1380)
    }

    @Test func zeroPxPerMinuteDoesNotCrash() {
        // Defensive: a degenerate scale falls back to 1, never divides by zero.
        #expect(ProCalendarGrid.draggedStartMinutes(
            originalStartMinutes: 600, translationPoints: 30, pxPerMinute: 0,
            durationMinutes: 60, stepMinutes: 15) == 630)
    }

    // ── resize (bottom-edge drag → new duration) ──

    /// Resize a tile at `start` (minutes) with `duration` by dragging its bottom
    /// edge `points` vertically; the start stays fixed, only the end/duration moves.
    private func resized(from start: Int, duration: Int, drag points: Double) -> Int {
        ProCalendarGrid.resizedDurationMinutes(
            originalStartMinutes: start,
            originalDurationMinutes: duration,
            translationPoints: points,
            pxPerMinute: px,
            stepMinutes: step)
    }

    @Test func dragBottomDownLengthensByOneStep() {
        // 10:00–11:00 (60m); drag the bottom +22.5pt (15 min) → 75 min.
        #expect(resized(from: 600, duration: 60, drag: 22.5) == 75)
    }

    @Test func dragBottomUpShortens() {
        // 10:00–11:30 (90m); drag the bottom -45pt (-30 min) → 60 min.
        #expect(resized(from: 600, duration: 90, drag: -45) == 60)
    }

    @Test func resizeSubStepDragSnapsToNearestStep() {
        // ~6.7 min rounds to 0 steps (no change); ~8 min rounds up one step.
        #expect(resized(from: 600, duration: 60, drag: 10) == 60)
        #expect(resized(from: 600, duration: 60, drag: 12) == 75)
    }

    @Test func resizeOffGridEndSnapsToTheGrid() {
        // An off-grid end (10:00 + 67m = 11:07) with no drag snaps its end to the
        // 15-min grid (11:00) → a clean 60-min duration.
        #expect(resized(from: 600, duration: 67, drag: 0) == 60)
    }

    @Test func resizeClampsToMinimumOneStep() {
        // Dragging the bottom far above the start can't invert the tile — it holds
        // at one step (15 min).
        #expect(resized(from: 600, duration: 90, drag: -10_000) == 15)
    }

    @Test func resizeClampsSoDurationFitsBeforeMidnight() {
        // A tile starting 23:00 (1380) can't stretch past midnight: max 60 min.
        #expect(resized(from: 1380, duration: 30, drag: 10_000) == 60)
    }

    @Test func resizeClampsToMaxDuration() {
        // From midnight the day has 24h of room, but a single appointment caps at
        // the 12h `maxDurationMinutes` (720).
        #expect(resized(from: 0, duration: 60, drag: 100_000) == 720)
    }

    @Test func resizeZeroPxPerMinuteDoesNotCrash() {
        // Degenerate scale falls back to 1 px/min, never divides by zero.
        #expect(ProCalendarGrid.resizedDurationMinutes(
            originalStartMinutes: 600, originalDurationMinutes: 60,
            translationPoints: 30, pxPerMinute: 0, stepMinutes: 15) == 90)
    }

    // ── cross-day drop target (x → day column) ──

    private let weekColumns: [(key: String, minX: Double, maxX: Double)] = [
        (key: "2026-07-13", minX: 52, maxX: 100),   // Mon (past the 52pt gutter)
        (key: "2026-07-14", minX: 100, maxX: 148),  // Tue
        (key: "2026-07-15", minX: 148, maxX: 196),  // Wed
        (key: "2026-07-16", minX: 196, maxX: 244),  // Thu
    ]

    @Test func dropXPicksTheColumnItLandsIn() {
        #expect(ProCalendarGrid.dayColumnForX(120, columns: weekColumns) == "2026-07-14")
        #expect(ProCalendarGrid.dayColumnForX(200, columns: weekColumns) == "2026-07-16")
    }

    @Test func dropXOnBandStartIsInclusiveEndIsExclusive() {
        // A shared divider pixel (a column's maxX == the next's minX) resolves to the
        // right-hand column, never both.
        #expect(ProCalendarGrid.dayColumnForX(148, columns: weekColumns) == "2026-07-15")
        #expect(ProCalendarGrid.dayColumnForX(52, columns: weekColumns) == "2026-07-13")
    }

    @Test func dropXOutsideAllColumnsIsNil() {
        // Left of the first column (in the gutter) or right of the last → nil, so the
        // caller keeps the tile on its original day.
        #expect(ProCalendarGrid.dayColumnForX(10, columns: weekColumns) == nil)
        #expect(ProCalendarGrid.dayColumnForX(300, columns: weekColumns) == nil)
    }

    @Test func dropXSingleColumnDayView() {
        // Day view has one column; an in-band x returns it, an out-of-band x is nil.
        let one: [(key: String, minX: Double, maxX: Double)] = [(key: "2026-07-15", minX: 52, maxX: 393)]
        #expect(ProCalendarGrid.dayColumnForX(200, columns: one) == "2026-07-15")
        #expect(ProCalendarGrid.dayColumnForX(20, columns: one) == nil)
    }

    // ── minutes → instant ──

    @Test func instantRoundTripsWithinTheDay() {
        // Local midnight 2026-07-15 PDT + 630 min = 10:30 PDT (no DST transition).
        let midnight = startOfDay(2026, 7, 15)
        let at = ProCalendarGrid.instant(dayStart: midnight, minutes: 630, timeZone: zone)!
        #expect(ProCalendarGrid.ymd(at, zone) == "2026-07-15")
        #expect(ProCalendarGrid.minutesSinceMidnight(at, zone) == 630)

        let late = ProCalendarGrid.instant(dayStart: midnight, minutes: 1350, timeZone: zone)!
        #expect(ProCalendarGrid.minutesSinceMidnight(late, zone) == 1350) // 22:30
    }

    // ── label ──

    @Test func minuteOfDayLabelFormats() {
        #expect(ProCalendarGrid.minuteOfDayLabel(0) == "12:00am")
        #expect(ProCalendarGrid.minuteOfDayLabel(615) == "10:15am")
        #expect(ProCalendarGrid.minuteOfDayLabel(720) == "12:00pm")
        #expect(ProCalendarGrid.minuteOfDayLabel(825) == "1:45pm")
        #expect(ProCalendarGrid.minuteOfDayLabel(1425) == "11:45pm")
    }

    // ── helpers ──

    private func startOfDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let noon = cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
        return cal.startOfDay(for: noon)
    }
}
