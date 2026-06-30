import Foundation

// Wire models for the PRO aftercare list — GET /api/v1/pro/aftercare (tovis-app
// PR #436). Mirrors `ProAftercareListItem` (ProAftercareCard + media) from
// lib/aftercare/proAftercareList.ts: the Draft / Sent / Finished card with its
// rebook chip, relative activity stamp and before/after thumbnails.

/// `GET /api/v1/pro/aftercare` → `{ ok, items }` (envelope's `ok` ignored).
public struct ProAftercareListResponse: Decodable, Sendable {
    public let items: [ProAftercareCardItem]
}

public struct ProAftercareCardItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let bookingId: String
    public let href: String
    public let serviceName: String
    public let clientName: String
    public let initials: String
    /// "draft" · "sent" · "finished".
    public let status: String
    public let bookingDateLabel: String?
    public let rebook: Rebook?
    public let ago: Ago?
    /// "send" · "nudge" · null (the open-loop action).
    public let action: String?
    public let needsAction: Bool
    public let searchText: String
    /// Activity timestamp (ms) — the recency sort key.
    public let sortKey: Double
    public let media: Media?

    public struct Rebook: Decodable, Sendable {
        /// "recommended" · "overdue" · "next".
        public let kind: String
        public let value: String
    }

    public struct Ago: Decodable, Sendable {
        /// "saved" · "sent" · "booked".
        public let verb: String
        public let value: String
    }

    public struct Media: Decodable, Sendable {
        public let beforeUrl: String?
        public let afterUrl: String?
    }
}
