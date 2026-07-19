import Foundation

/// One day's worth of items, in the order the days first appeared in the source
/// list (the feeds arrive newest-first, so that ordering is already the one the
/// UI wants — this never re-sorts).
public struct DayGroup<Item> {
    /// `yyyy-MM-dd` in the grouping calendar's time zone. Used as the `ForEach`
    /// identity, so it must stay stable across renders — it is built from a
    /// *Gregorian* calendar pinned to `calendar`'s time zone, matching the
    /// `en_US_POSIX` formatter this replaced. A device set to a non-Gregorian
    /// calendar would otherwise key on an era-relative year (Buddhist 2568 for
    /// Gregorian 2026).
    public let key: String
    /// Midnight of this group's day, in the grouping calendar. Carried so
    /// `DayGrouping.heading(for:)` never has to parse `key` back into a `Date`.
    public let day: Date
    public let items: [Item]
}

/// Groups a notification feed into day sections and titles them the way web
/// does — `Today` / `Yesterday` / `EEE, MMM d`.
///
/// Both notification screens (`NotificationsView`, `ProNotificationsView`) had
/// this hand-copied, byte-identical apart from the element type. They differ
/// only in *what* they group (`ClientNotification` vs `ProNotification`) and
/// where the timestamp lives on it, so the element type stays generic and the
/// timestamp arrives as a projection closure rather than via a protocol the
/// wire models would have to conform to.
public enum DayGrouping {
    /// Buckets `items` by calendar day, preserving first-seen day order and the
    /// within-day order of the source list.
    ///
    /// - Parameters:
    ///   - calendar: defaults to `.current`; injectable so tests can pin a zone.
    ///   - date: the timestamp to bucket on. Callers decoding a wire string pass
    ///     their own fallback (`Wire.date(x) ?? Date()`), which is why this takes
    ///     a non-optional `Date` and leaves the unparseable case to them.
    public static func byDay<Item>(
        _ items: [Item],
        calendar: Calendar = .current,
        date: (Item) -> Date
    ) -> [DayGroup<Item>] {
        // Built once, not per item — a Calendar is not free to construct.
        var keyCalendar = Calendar(identifier: .gregorian)
        keyCalendar.timeZone = calendar.timeZone

        var order: [String] = []
        var itemsByKey: [String: [Item]] = [:]
        var dayByKey: [String: Date] = [:]

        for item in items {
            let day = calendar.startOfDay(for: date(item))
            let key = dayKey(for: day, calendar: keyCalendar)
            if itemsByKey[key] == nil {
                order.append(key)
                dayByKey[key] = day
            }
            itemsByKey[key, default: []].append(item)
        }

        return order.map { key in
            DayGroup(
                key: key,
                // Both defaults are unreachable: a key only enters `order` in the
                // same step that populates both dictionaries.
                day: dayByKey[key] ?? Date(),
                items: itemsByKey[key] ?? []
            )
        }
    }

    /// The section title for a group's `day`.
    ///
    /// - Parameter now: defaults to the current instant; injectable so a test can
    ///   pin "today" instead of racing midnight.
    public static func heading(
        for day: Date,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        // Allocated per call rather than cached in a `static let`: a DateFormatter
        // is not Sendable, and the call count is bounded by the number of distinct
        // days on screen (single digits), not by the item count — the shape that
        // actually matters for ICU cost.
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US")
        out.dateFormat = "EEE, MMM d"
        return out.string(from: day)
    }

    /// `yyyy-MM-dd`, without a DateFormatter — see `DayGroup.key`.
    private static func dayKey(for day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
