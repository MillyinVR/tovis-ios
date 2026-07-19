// The caption + service-chip panel the full-screen media viewer overlays on a
// portfolio asset — the native counterpart of web's `/media/[id]` bottom panel
// (caption line + a "Services" label above name chips).
//
// The rule lives here, in TovisKit, rather than in the view so `swift test`
// reaches it: what counts as "nothing to show", how many chips fit, and the
// blank/duplicate handling are decisions, not layout.
import Foundation

/// What the full-screen viewer should overlay for a piece of media, after the
/// blank/duplicate/cap rules are applied. `nil` from ``make(caption:serviceNames:)``
/// means render no panel at all.
public struct MediaCaptionOverlay: Equatable, Sendable {
    /// Trimmed caption, or `nil` when the media has none.
    public let caption: String?
    /// Trimmed, de-duplicated service names, capped at ``chipLimit``.
    public let serviceNames: [String]

    /// Web renders at most six chips (`tagNames.slice(0, 6)`); more than that
    /// wraps into a wall of pills that covers the photo the viewer opened.
    public static let chipLimit = 6

    /// Builds the overlay, or `nil` when there is nothing worth covering the
    /// media with. A blank caption and an all-blank tag list both collapse to
    /// `nil`, so a whitespace-only caption never renders an empty panel.
    public static func make(
        caption: String?,
        serviceNames: [String]
    ) -> MediaCaptionOverlay? {
        let trimmedCaption = caption?.trimmedOrNil

        var seen = Set<String>()
        var names: [String] = []
        for name in serviceNames {
            guard let value = name.trimmedOrNil, !seen.contains(value) else { continue }
            seen.insert(value)
            names.append(value)
            if names.count == chipLimit { break }
        }

        if trimmedCaption == nil && names.isEmpty { return nil }
        return MediaCaptionOverlay(caption: trimmedCaption, serviceNames: names)
    }
}
