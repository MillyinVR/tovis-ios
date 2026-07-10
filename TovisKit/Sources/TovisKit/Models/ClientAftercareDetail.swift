import Foundation

// Wire models for the client's aftercare read — GET
// /api/v1/client/bookings/{id}/aftercare. Returns the client-visible aftercare:
// care notes (only once the pro has SENT the summary) + the pro's featured
// before/after pair (else earliest per phase). Mirrors web
// `lib/dto/clientAftercare.ts` (`ClientAftercareDetailDTO`), which the web
// booking-detail aftercare tab renders server-side. Decode-only; the top-level
// `{ ok, … }` envelope's `ok` flag is simply ignored (unknown key).

/// GET .../aftercare → `{ ok, canShowAftercare, aftercare, beforeAfter }`.
public struct ClientAftercareDetail: Decodable, Sendable {
    /// Whether the client's aftercare surface should show — mirrors web's
    /// `canShowAftercareTab` gate (booking COMPLETED, or a sent summary exists).
    /// The native client hides the whole section when false.
    public let canShowAftercare: Bool
    /// The SENT aftercare summary (care notes), or nil when none is sent yet.
    public let aftercare: ClientAftercareSummary?
    /// Primary before/after pair (featured, else earliest per phase).
    public let beforeAfter: ClientAftercareBeforeAfter

    /// True when there's something to render — care notes or at least one photo.
    /// (`canShowAftercare` can be true for a COMPLETED booking with neither yet.)
    public var hasContent: Bool {
        let hasNotes = (aftercare?.notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        return hasNotes || beforeAfter.hasAny
    }
}

/// The care-notes slice of a sent aftercare summary the client may read.
public struct ClientAftercareSummary: Decodable, Sendable, Identifiable {
    public let id: String
    /// Free-text care instructions the pro wrote for the client.
    public let notes: String?
    /// ISO instant the pro sent this aftercare to the client.
    public let sentToClientAt: String?
}

/// Primary before/after render URLs (thumb + full-size), any of which may be nil.
public struct ClientAftercareBeforeAfter: Decodable, Sendable {
    public let beforeUrl: String?
    public let afterUrl: String?
    public let beforeFullUrl: String?
    public let afterFullUrl: String?

    /// True when at least one phase has a usable URL.
    public var hasAny: Bool {
        [beforeUrl, afterUrl, beforeFullUrl, afterFullUrl]
            .contains { ($0?.isEmpty == false) }
    }

    /// Full-size-preferred "before" URL for the hero compare + tap-to-open.
    public var beforePreferred: String? { beforeFullUrl ?? beforeUrl }
    /// Full-size-preferred "after" URL for the hero compare + tap-to-open.
    public var afterPreferred: String? { afterFullUrl ?? afterUrl }
}
