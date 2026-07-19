import Foundation

/// Compact engagement counts — "999" / "1.2K" / "12.5K" / "1.2M".
///
/// The single compact-count rule for the app. The look surfaces at least must
/// agree — the feed rail and the single-look detail show the SAME counters for
/// the SAME look, so a viewer who taps through from a shared link must not see
/// "1.2K" become "1200".
///
/// ## The canonical rule is web's, and this now matches it exactly
///
/// `tovis-app/lib/format/compactCount.ts` settled the cross-platform contract in
/// web #680: `Intl.NumberFormat` compact notation (en-US) — uppercase K/M/B/T,
/// at most one fraction digit, no trailing ".0", and correct rollover.
///
/// This formerly had **no M branch at all**, so it rendered 1,000,000 as
/// "1000K" and 999,999 as "1000.0K" — the same bug web #680 fixed, which is why
/// the two platforms previously agreed only below a million. Round-3 queue item
/// 15 closed it. `CompactCountTests` pins the agreement value-for-value against
/// `lib/format/compactCount.test.ts`.
///
/// ⚠️ Rounding happens BEFORE the unit is chosen, which is what makes 999,999
/// read "1M" rather than a four-digit "1000K". Picking the unit first and
/// rounding after reintroduces exactly the bug this module exists to prevent.
///
/// ⚠️ Prefer a server-formatted `*Label` field when the DTO offers one (see
/// `PublicProfileStatsDto`, which is 5-of-6 `*Label`s precisely so formatting
/// stays server-side). This exists only for payloads that ship raw counters —
/// `LooksFeedItemDto._count`, `LooksDetailItemDto._count` and
/// `ProLooksAnalytics.LookStats` all do.
public enum CompactCount {
    /// The compact units, smallest first. Anything at or above the largest is
    /// rendered in it rather than overflowing to a unit that does not exist.
    private static let units: [(divisor: Double, suffix: String)] = [
        (1_000, "K"),
        (1_000_000, "M"),
        (1_000_000_000, "B"),
        (1_000_000_000_000, "T"),
    ]

    /// "999" below 1000, then "1.2K" / "12.5K" / "1.2M" (a whole unit drops the
    /// ".0"). Negative counts normalize to "0" — `FollowToggle` clamps at zero,
    /// but a stale server count can still arrive negative, and web does the same
    /// via `Math.max(0, …)`.
    public static func label(_ n: Int) -> String {
        let value = max(0, n)
        guard value >= 1000 else { return "\(value)" }

        for (index, unit) in units.enumerated() {
            let magnitude = round1(Double(value) / unit.divisor)
            // Round first, THEN decide: 999,999 scales to 999.999K, rounds to
            // 1000K, and so belongs in the next unit up as "1M".
            if magnitude < 1000 || index == units.count - 1 {
                return trimmedMagnitude(magnitude) + unit.suffix
            }
        }

        // Unreachable — the loop always returns on its last iteration.
        return "\(value)"
    }

    /// "1 follower" / "12 followers" / "1.2K followers".
    public static func followers(_ n: Int) -> String {
        let value = max(0, n)
        guard value >= 1000 else { return value == 1 ? "1 follower" : "\(value) followers" }
        return "\(label(value)) followers"
    }

    /// Round to one fraction digit, half away from zero — `Intl`'s default
    /// rounding mode ("halfExpand") for the same inputs.
    private static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    /// "1.2", or "12" when the fraction is zero (web emits no trailing ".0").
    private static func trimmedMagnitude(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(value))"
            : String(format: "%.1f", value)
    }
}
