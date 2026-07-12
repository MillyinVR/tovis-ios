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
