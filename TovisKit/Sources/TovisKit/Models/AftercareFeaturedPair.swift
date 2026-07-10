import Foundation

// Pure, testable logic for the pro's featured before/after pair picker — the
// native counterpart to web `lib/aftercare/featuredPairSeed.ts` and the
// `validFeaturedBefore` / `validFeaturedAfter` guard in `AftercareForm`. Kept
// UI-free (in TovisKit) so the partition + validation are unit-tested without a
// SwiftUI host, matching how the web helper is a pure module.
public enum AftercareFeaturedPair {
    /// Partition a booking's media into the before/after IMAGE candidates the
    /// featured-pair picker offers, each phase earliest-first — mirroring the web
    /// picker, where the first BEFORE / first AFTER is the default "primary" the
    /// client sees when no pair is featured. Videos are excluded: the before/after
    /// comparison is image-only, so only images are featurable (web:
    /// "The reveal comparison is image-only, so only images are featurable").
    public static func candidates(
        _ items: [ProBookingMediaItem]
    ) -> (before: [ProBookingMediaItem], after: [ProBookingMediaItem]) {
        // ISO-8601 UTC timestamps of the same shape sort chronologically as
        // strings, so a lexical sort == earliest-first (matches web's ascending
        // `createdAt` order for the "primary = earliest" default).
        let sorted = items
            .filter { $0.mediaType == .image }
            .sorted { $0.createdAt < $1.createdAt }
        return (
            before: sorted.filter { $0.phase == .before },
            after: sorted.filter { $0.phase == .after }
        )
    }

    /// Keep a selected featured id only when it still maps to a current
    /// candidate of that phase — else `nil`. Mirrors web's `validFeaturedBefore`
    /// guard so a stale / foreign / deleted id is never sent (the server write
    /// boundary would reject it, failing the whole save). A `nil` selection stays
    /// `nil` (explicitly clears the pair). Pass the phase-specific candidate list
    /// from ``candidates(_:)``.
    public static func resolveValidFeaturedId(
        _ selectedId: String?,
        in candidates: [ProBookingMediaItem]
    ) -> String? {
        guard let selectedId,
            candidates.contains(where: { $0.id == selectedId })
        else { return nil }
        return selectedId
    }
}
