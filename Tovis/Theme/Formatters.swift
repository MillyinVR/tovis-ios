import Foundation

/// Display formatting for wire values (ISO-8601 instants + decimal-string money).
///
/// The backend stores instants as UTC and sends them as ISO strings; we resolve
/// a timezone only here, at the edge (mirrors the web app's `lib/time` rule).
enum Wire {
    /// Parse a backend ISO-8601 instant (with or without fractional seconds).
    static func date(_ iso: String) -> Date? {
        if let d = isoWithFraction.date(from: iso) { return d }
        return isoPlain.date(from: iso)
    }

    /// e.g. "Tue, Jul 1 · 10:00 AM" rendered in `timeZone` (or the device zone).
    static func dateTime(_ iso: String, timeZone: String?) -> String {
        guard let date = date(iso) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        f.dateFormat = "EEE, MMM d · h:mm a"
        return f.string(from: date)
    }

    /// e.g. "Jul 1, 2026" rendered in `timeZone` (or the device zone). Date only.
    static func dateOnly(_ iso: String, timeZone: String? = nil) -> String {
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
    static func monthDay(_ iso: String, timeZone: String? = nil) -> String {
        guard let date = date(iso) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    /// Short relative age of a backend ISO instant, e.g. "now", "5m", "3h",
    /// "2d", or a "MMM d" date for older items. Used by notification timestamps.
    static func relativeAgo(_ iso: String, now: Date = Date()) -> String {
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
    static func nowISO() -> String {
        isoWithFraction.string(from: Date())
    }

    /// Format a decimal-string amount (e.g. "120.00") as USD currency: "$120".
    static func money(_ amount: String?) -> String? {
        guard let amount, let value = Decimal(string: amount) else { return nil }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        // Drop ".00" but keep real cents (e.g. $45 / $45.50).
        f.minimumFractionDigits = value == value.rounded(0) ? 0 : 2
        return f.string(from: value as NSDecimalNumber)
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
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
