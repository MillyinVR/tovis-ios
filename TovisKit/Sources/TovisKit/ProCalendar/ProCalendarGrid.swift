import Foundation

// Pure, timezone-aware date math for the PRO calendar's view switcher + month
// grid — the native counterpart of the web `_utils/calendarRange.ts` +
// `_viewModel/proCalendarDisplay.ts`. Weeks start **Monday** to match the web
// (`WEEK_START = 'MON'`); the month grid is a fixed 42 cells (6 weeks) like the
// web `MONTH_GRID_DAY_COUNT`. All math is anchored in the calendar's timezone so
// it lines up 1:1 with the server's viewport-zone `localDateKey` on each event.

/// Which slice of the schedule the calendar is showing.
public enum ProCalendarViewMode: String, Sendable, CaseIterable {
    case day, week, month
}

/// One cell of the month grid (6×7). `dayYmd` is the local "yyyy-MM-dd" in the
/// calendar zone — it matches a `ProCalendarEvent.localDateKey` for bucketing.
public struct ProMonthCell: Sendable, Identifiable, Equatable {
    public let dayYmd: String
    public let dayNumber: Int
    public let isToday: Bool
    public let isInCurrentMonth: Bool
    /// UTC instant of the cell's local midnight (used as the day-view anchor).
    public let startOfDay: Date

    public var id: String { dayYmd }
}

public enum ProCalendarGrid {
    // ─── Calendar / formatting primitives ──────────────────────────────────

    /// A Monday-start Gregorian calendar pinned to `timeZone` (mirrors the web's
    /// `WEEK_START = 'MON'`).
    static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.firstWeekday = 2 // Monday
        return cal
    }

    /// Local "yyyy-MM-dd" in `timeZone` — the same key shape the server emits.
    public static func ymd(_ date: Date, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Anchor a date to local noon in `timeZone` — DST-safe stable day anchor
    /// (the web stores `currentDate` the same way via `anchorNoonInTimeZone`).
    public static func anchorNoon(_ date: Date, timeZone: TimeZone) -> Date {
        let cal = gregorian(timeZone)
        return cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
    }

    // ─── Week / month boundaries ────────────────────────────────────────────

    static func weekStart(reference: Date, cal: Calendar) -> Date {
        let start = cal.startOfDay(for: reference)
        let weekday = cal.component(.weekday, from: start) // 1=Sun … 7=Sat
        let offset = (weekday - cal.firstWeekday + 7) % 7
        return cal.date(byAdding: .day, value: -offset, to: start) ?? start
    }

    /// 42-cell month grid (6 weeks, Monday-start) covering `reference`'s month.
    public static func monthCells(
        reference: Date,
        timeZone: TimeZone,
        today: Date
    ) -> [ProMonthCell] {
        let cal = gregorian(timeZone)
        let monthComps = cal.dateComponents([.year, .month], from: reference)
        guard
            let firstOfMonth = cal.date(from: monthComps),
            let refMonth = monthComps.month
        else { return [] }

        let gridStart = weekStart(reference: firstOfMonth, cal: cal)
        let todayYmd = ymd(today, timeZone)

        return (0..<42).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: gridStart)
            else { return nil }
            let start = cal.startOfDay(for: day)
            let comps = cal.dateComponents([.month, .day], from: start)
            let key = ymd(start, timeZone)
            return ProMonthCell(
                dayYmd: key,
                dayNumber: comps.day ?? 0,
                isToday: key == todayYmd,
                isInCurrentMonth: comps.month == refMonth,
                startOfDay: start
            )
        }
    }

    // ─── Fetch range / navigation ───────────────────────────────────────────

    /// The `[from, to)` instants to request for a view anchored on `reference`.
    /// Day = that day; week = its Mon–Sun; month = the full 42-cell grid window.
    public static func fetchRange(
        view: ProCalendarViewMode,
        reference: Date,
        timeZone: TimeZone
    ) -> (from: Date, to: Date) {
        let cal = gregorian(timeZone)
        switch view {
        case .day:
            let start = cal.startOfDay(for: reference)
            return (start, cal.date(byAdding: .day, value: 1, to: start) ?? start)
        case .week:
            let start = weekStart(reference: reference, cal: cal)
            return (start, cal.date(byAdding: .day, value: 7, to: start) ?? start)
        case .month:
            let cells = monthCells(reference: reference, timeZone: timeZone, today: reference)
            let start = cells.first?.startOfDay ?? cal.startOfDay(for: reference)
            let end = cal.date(byAdding: .day, value: 42, to: start) ?? start
            return (start, end)
        }
    }

    /// Shift the anchor date by `delta` view-units (day/week/month), re-anchored
    /// to local noon for DST safety (mirrors the web `shiftDate`).
    public static func step(
        view: ProCalendarViewMode,
        reference: Date,
        by delta: Int,
        timeZone: TimeZone
    ) -> Date {
        let cal = gregorian(timeZone)
        let stepped: Date?
        switch view {
        case .day:   stepped = cal.date(byAdding: .day, value: delta, to: reference)
        case .week:  stepped = cal.date(byAdding: .day, value: delta * 7, to: reference)
        case .month: stepped = cal.date(byAdding: .month, value: delta, to: reference)
        }
        return anchorNoon(stepped ?? reference, timeZone: timeZone)
    }

    // ─── Header label ───────────────────────────────────────────────────────

    /// Range label for the controls bar — month "July 2026" · week
    /// "Jun 30 – Jul 6" · day "Tue, Jul 1" (mirrors the web header formatters).
    public static func headerLabel(
        view: ProCalendarViewMode,
        reference: Date,
        timeZone: TimeZone
    ) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = timeZone
        switch view {
        case .day:
            f.dateFormat = "EEE, MMM d"
            return f.string(from: reference)
        case .week:
            let cal = gregorian(timeZone)
            let start = weekStart(reference: reference, cal: cal)
            let end = cal.date(byAdding: .day, value: 6, to: start) ?? start
            f.dateFormat = "MMM d"
            return "\(f.string(from: start)) – \(f.string(from: end))"
        case .month:
            f.dateFormat = "MMMM yyyy"
            return f.string(from: reference)
        }
    }

    /// ISO-8601 instant for a `from`/`to` calendar query param.
    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
