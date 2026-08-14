import Foundation

/// Day-granularity relative timestamps — "today", "yesterday", "3d ago",
/// "2w ago" — falling back to a short month/day date past five weeks.
///
/// The twin of web's `formatRelativeDayAgo` (`lib/time/relativeTime.ts`), used
/// where a row talks in days rather than minutes: the "your looks, remixed"
/// list, whose entries are appointments other people booked.
///
/// ⚠️ Deliberately NOT `ActivityTimeAgo`, which buckets by ELAPSED time
/// ("5m ago", "3h ago"). "Today" and "yesterday" are claims about the calendar,
/// so they are decided by day boundaries in `timeZone`: something booked at
/// 11:50pm is "yesterday" at 12:10am, not "today" for another 23 hours. The two
/// are different rules with different wording, not duplicates.
public enum RelativeDayAgo {
    /// Past this many days, a calendar date reads better than a week count.
    private static let weekCapDays = 35

    public static func label(
        _ iso: String,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        guard let then = Wire.date(iso) else { return "" }
        return label(then, now: now, timeZone: timeZone)
    }

    public static func label(
        _ then: Date,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        // A future instant clamps to zero elapsed days — web does `Math.max(0, …)`
        // so clock skew reads "today" rather than a negative age.
        let days = max(
            0,
            calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: then),
                to: calendar.startOfDay(for: now)
            ).day ?? 0
        )

        if days < 1 { return "today" }
        if days < 2 { return "yesterday" }
        if days < 7 { return "\(days)d ago" }
        if days < weekCapDays { return "\(days / 7)w ago" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: then)
    }
}
