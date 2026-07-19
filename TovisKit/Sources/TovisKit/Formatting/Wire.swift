import Foundation

/// Display formatting for wire values (ISO-8601 instants + decimal-string money).
///
/// The backend stores instants as UTC and sends them as ISO strings; we resolve
/// a timezone only here, at the edge (mirrors the web app's `lib/time` rule).
///
/// Lives in TovisKit rather than the app target so `swift test` can reach it —
/// it sat in `Tovis/Theme/Formatters.swift` while its siblings (`DayGrouping`,
/// `ActivityTimeAgo`, `ProCalendarGrid.parseISO`) were already here, which is
/// why TovisKit could only refer to it in comments.
///
/// ⚠️ `relativeAgo` is the COMPACT relative formatter ("5m", no suffix). The
/// activity feed's `ActivityTimeAgo` ("5m ago", week bucket) is deliberately
/// separate — web ships both off one bucketing core
/// (`formatRelativeTimeCompact` / `formatRelativeTimeAgo`) and iOS mirrors
/// both. They are NOT duplicates; collapsing them would change copy.
public enum Wire {
    /// Parse a backend ISO-8601 instant (with or without fractional seconds).
    public static func date(_ iso: String) -> Date? {
        if let d = isoWithFraction.date(from: iso) { return d }
        return isoPlain.date(from: iso)
    }

    /// e.g. "Tue, Jul 1 · 10:00 AM" rendered in `timeZone` (or the device zone).
    public static func dateTime(_ iso: String, timeZone: String?) -> String {
        guard let date = date(iso) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        f.dateFormat = "EEE, MMM d · h:mm a"
        return f.string(from: date)
    }

    /// e.g. "Jul 1, 2026" rendered in `timeZone` (or the device zone). Date only.
    public static func dateOnly(_ iso: String, timeZone: String? = nil) -> String {
        guard let date = date(iso) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }

    /// e.g. "Jul 1" rendered in `timeZone` (or the device zone). Month + day, no
    /// year — the compact "joined …" label the waitlist/outreach rows use (mirrors
    /// web's `month:'short', day:'numeric'`). Returns "" for an unparseable value.
    public static func monthDay(_ iso: String, timeZone: String? = nil) -> String {
        guard let date = date(iso) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    /// Short relative age of a backend ISO instant, e.g. "now", "5m", "3h",
    /// "2d", or a "MMM d" date for older items. Used by notification timestamps.
    public static func relativeAgo(_ iso: String, now: Date = Date()) -> String {
        guard let date = date(iso) else { return "" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        if days < 7 { return "\(days)d" }

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = .current
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    /// The current instant as a backend-style ISO-8601 string (fractional
    /// seconds), for optimistic rows shown before the server's own timestamp.
    public static func nowISO() -> String {
        isoWithFraction.string(from: Date())
    }

    /// Format a decimal-string amount (e.g. "120.00") as USD currency: "$120".
    public static func money(_ amount: String?) -> String? {
        guard let amount else { return nil }
        return moneyDecimal(Decimal(string: amount))
    }

    /// Format a `Decimal` amount as USD currency ("$120" / "$45.50"); nil → nil. For
    /// amounts that are computed rather than arriving as a wire string (e.g. an
    /// opening's discounted price). `money(_:)` delegates here so the two share one
    /// formatter.
    public static func moneyDecimal(_ value: Decimal?) -> String? {
        guard let value else { return nil }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        // Drop ".00" but keep real cents (e.g. $45 / $45.50).
        f.minimumFractionDigits = value == value.rounded(0) ? 0 : 2
        return f.string(from: value as NSDecimalNumber)
    }

    /// Format an integer-cents amount (e.g. 12000 → "$120", 4550 → "$45.50") as
    /// currency, honoring the wire `currency` code. Mirrors the web
    /// `formatCents(cents, { currency, style: 'symbol' })`. Returns nil for nil.
    public static func moneyCents(_ cents: Int?, currency: String = "usd") -> String? {
        guard let cents else { return nil }
        let value = Decimal(cents) / 100
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency.uppercased()
        f.locale = Locale(identifier: "en_US")
        // Drop ".00" but keep real cents (e.g. $45 / $45.50).
        f.minimumFractionDigits = value == value.rounded(0) ? 0 : 2
        return f.string(from: value as NSDecimalNumber)
    }

    // ⚠️ `nonisolated(unsafe)` rather than rebuilding per call. Crossing into
    // TovisKit subjected these to strict-concurrency checking the app target was
    // not applying, and `ISO8601DateFormatter` is not `Sendable`. Both instances
    // are configured once here and never mutated again, and Foundation documents
    // formatting/parsing as thread-safe — so the unsafe opt-out is accurate,
    // where rebuilding per call would allocate a formatter for every list row
    // that renders a date. (TovisKit's older `ProCalendarGrid.parseISO` does
    // rebuild; it predates this and is not on a per-row path.)
    nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

private extension Decimal {
    /// Round to `scale` decimal places (banker's-free, plain).
    func rounded(_ scale: Int) -> Decimal {
        var result = Decimal()
        var copy = self
        NSDecimalRound(&result, &copy, scale, .plain)
        return result
    }
}
