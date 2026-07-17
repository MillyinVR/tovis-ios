import Foundation

/// Compact engagement counts — "999" / "1.2K" / "12K".
///
/// The rule lives here because the app already carries several divergent
/// compact-count impls (`LooksView` → "1.2K", `ProLooksPerformanceView` →
/// "1.2k", `ProProfileView` → raw), and the look surfaces at least must agree:
/// the feed rail and the single-look detail show the SAME counters for the SAME
/// look, so a viewer who taps through from a shared link must not see "1.2K"
/// become "1200".
///
/// This is a verbatim extraction of the feed's own formatter (`LooksView`'s
/// private `countLabel`/`followerLabel`), pinned by CompactCountTests. The two
/// pro-side impls are deliberately left alone — folding them in would change
/// their rendered output, which is a decision, not a refactor.
///
/// ⚠️ Prefer a server-formatted `*Label` field when the DTO offers one (see
/// `PublicProfileStatsDto`, which is 5-of-6 `*Label`s precisely so formatting
/// stays server-side). This exists only for payloads that ship raw counters —
/// `LooksFeedItemDto._count` and `LooksDetailItemDto._count` both do.
public enum CompactCount {
    /// "999" below 1000, then "1.2K" / "12K" (a whole thousand drops the ".0").
    public static func label(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        let k = Double(n) / 1000
        return k.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(k))K"
            : String(format: "%.1fK", k)
    }

    /// "1 follower" / "12 followers" / "1.2K followers".
    public static func followers(_ n: Int) -> String {
        guard n >= 1000 else { return n == 1 ? "1 follower" : "\(n) followers" }
        return "\(label(n)) followers"
    }
}
