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

    // ─── Day/Week time-grid layout (web _grid/DayColumn buildEventLayout) ────

    public static let minutesPerDay = 24 * 60

    /// Parse a backend ISO-8601 instant (with or without fractional seconds).
    static func parseISO(_ value: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    /// Minutes since local midnight in `timeZone` (0…1439).
    public static func minutesSinceMidnight(_ date: Date, _ timeZone: TimeZone) -> Int {
        let cal = gregorian(timeZone)
        let comps = cal.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    /// Round `minutes` to the nearest `step`, clamped to [0, 1440 - step] — the
    /// web `snapMinutes`. Public so the drag-to-reschedule layer in the app target
    /// can snap a dropped tile to the same 15-min grid the layout uses.
    public static func snap(_ minutes: Int, step: Int) -> Int {
        let s = max(1, step)
        let snapped = Int((Double(minutes) / Double(s)).rounded()) * s
        return max(0, min(minutesPerDay - s, snapped))
    }

    // ─── Drag-to-reschedule drop math (native port of web useDragDrop) ───────

    /// Where a dragged booking tile lands: convert a vertical drag translation
    /// (points) to minutes at `pxPerMinute`, add it to the tile's original start,
    /// snap to `stepMinutes`, and clamp so the whole appointment (`durationMinutes`)
    /// still fits before midnight. Pure so the drop position is unit-testable
    /// without driving the gesture (mirrors the web `startMinutesFromPointer`).
    public static func draggedStartMinutes(
        originalStartMinutes: Int,
        translationPoints: Double,
        pxPerMinute: Double,
        durationMinutes: Int,
        stepMinutes: Int
    ) -> Int {
        let px = pxPerMinute > 0 ? pxPerMinute : 1
        let deltaMinutes = Int((translationPoints / px).rounded())
        let maxStart = max(0, minutesPerDay - durationMinutes)
        return min(snap(originalStartMinutes + deltaMinutes, step: stepMinutes), maxStart)
    }

    /// The instant `minutes` past a day's local midnight (`dayStart` = the UTC
    /// instant of that midnight), in `timeZone`. Turns a dropped slot back into a
    /// `scheduledFor`. NB: this adds elapsed minutes (matching the empty-slot tap);
    /// on a DST-transition day a move across the 2–3am gap can shift by the offset,
    /// but same-day business-hours moves are unaffected.
    public static func instant(dayStart: Date, minutes: Int, timeZone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(byAdding: .minute, value: minutes, to: dayStart)
    }

    /// `h:mmam/pm` for a minutes-since-midnight value — the live drag / pending-move
    /// tile label (mirrors the now-line's `formatNowLabel`).
    public static func minuteOfDayLabel(_ minutes: Int) -> String {
        let h24 = (minutes / 60) % 24
        let m = ((minutes % 60) + 60) % 60
        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        return "\(h12):\(String(format: "%02d", m))\(h24 < 12 ? "am" : "pm")"
    }

    /// The ids among `[ (id, start, end) ]` intervals that overlap at least one other
    /// — the calendar's passive double-book highlight. Half-open [start, end): two
    /// appointments that merely touch (one's end == the other's start) do NOT count.
    public static func overlappingIntervalIds(
        _ intervals: [(id: String, start: Int, end: Int)]
    ) -> Set<String> {
        var ids: Set<String> = []
        for i in intervals.indices {
            for j in intervals.indices where j > i {
                let a = intervals[i], b = intervals[j]
                if a.start < b.end && b.start < a.end {
                    ids.insert(a.id)
                    ids.insert(b.id)
                }
            }
        }
        return ids
    }

    /// The client names of the bookings whose window overlaps the half-open
    /// `[proposedStart, proposedEnd)` — the new-booking form's passive
    /// double-book heads-up (native mirror of web `overlappingClientNamesForRange`).
    /// Half-open, so a back-to-back booking that merely touches does NOT warn;
    /// order-preserving and de-duplicated by name. A nameless overlap falls back
    /// to `fallbackName`. Callers pass real bookings only (BLOCK events — the
    /// pro's own time — filtered out first), matching the confirm-modal note.
    public static func overlappingClientNames(
        proposedStart: Date,
        proposedEnd: Date,
        events: [(id: String, clientName: String, start: Date, end: Date)],
        fallbackName: String
    ) -> [String] {
        guard proposedEnd > proposedStart else { return [] }

        var names: [String] = []
        var seen: Set<String> = []

        for event in events {
            guard event.start < proposedEnd && proposedStart < event.end else { continue }

            let trimmed = event.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = trimmed.isEmpty ? fallbackName : trimmed
            if seen.contains(display) { continue }

            seen.insert(display)
            names.append(display)
        }

        return names
    }

    /// The minutes-since-midnight `[start, end]` window an event occupies on
    /// `dayYmd` (the day cell's local key), TZ-aware with multi-day spillover and
    /// step snapping — the native port of `buildEventLayout`. Returns nil for an
    /// unparseable/zero-length event. `durationMinutes` is the server-provided
    /// duration used as the fallback length when the end falls on another day.
    public static func eventDayMinutes(
        startISO: String,
        endISO: String,
        durationMinutes: Int,
        dayYmd: String,
        timeZone: TimeZone,
        stepMinutes: Int
    ) -> (start: Int, end: Int)? {
        guard let start = parseISO(startISO) else { return nil }
        let end = parseISO(endISO)

        let startYmd = ymd(start, timeZone)
        let endYmdInclusive = end.map { ymd($0.addingTimeInterval(-0.001), timeZone) } ?? startYmd

        // Only lay out events that intersect this day (web `getDayEvents` filter).
        if dayYmd < startYmd || dayYmd > endYmdInclusive { return nil }

        let startMinutesRaw = dayYmd == startYmd ? minutesSinceMidnight(start, timeZone) : 0
        let endMinutesRaw: Int = {
            if dayYmd == endYmdInclusive, let end { return minutesSinceMidnight(end, timeZone) }
            return minutesPerDay
        }()

        let startMinutes = snap(startMinutesRaw, step: stepMinutes)
        let minEnd = startMinutes + stepMinutes

        let safeDuration = durationMinutes > 0 ? durationMinutes : 60
        let naturalEnd = endMinutesRaw <= startMinutesRaw
            ? startMinutesRaw + safeDuration
            : endMinutesRaw

        let safeEnd = max(minEnd, min(minutesPerDay, naturalEnd))
        return (startMinutes, safeEnd)
    }

    /// Whether `dayYmd` (a day cell key) is the local "today" in `timeZone`.
    public static func isToday(dayYmd: String, timeZone: TimeZone, now: Date) -> Bool {
        ymd(now, timeZone) == dayYmd
    }

    /// The day column(s) a timeline view spans — 1 for day, 7 (Mon-start) for
    /// week (the web `getTimelineDays`). Reuses `ProMonthCell` for the per-day
    /// key/number/today flags; `isInCurrentMonth` is unused here (always true).
    public static func timelineDays(
        view: ProCalendarViewMode,
        reference: Date,
        timeZone: TimeZone,
        today: Date
    ) -> [ProMonthCell] {
        let cal = gregorian(timeZone)
        switch view {
        case .day:
            return [dayCell(cal.startOfDay(for: reference), cal: cal, timeZone: timeZone, today: today)]
        case .week:
            let start = weekStart(reference: reference, cal: cal)
            return (0..<7).compactMap { offset in
                guard let day = cal.date(byAdding: .day, value: offset, to: start) else { return nil }
                return dayCell(cal.startOfDay(for: day), cal: cal, timeZone: timeZone, today: today)
            }
        case .month:
            return monthCells(reference: reference, timeZone: timeZone, today: today)
        }
    }

    private static func dayCell(
        _ start: Date, cal: Calendar, timeZone: TimeZone, today: Date
    ) -> ProMonthCell {
        let key = ymd(start, timeZone)
        return ProMonthCell(
            dayYmd: key,
            dayNumber: cal.component(.day, from: start),
            isToday: key == ymd(today, timeZone),
            isInCurrentMonth: true,
            startOfDay: start
        )
    }
}
