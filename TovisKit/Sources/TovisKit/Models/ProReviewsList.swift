import Foundation

// Wire models for the PRO reviews list — GET /api/v1/pro/reviews (tovis-app
// PR #438). Mirrors `ProReviewListItem` from lib/pro/loadProReviewsList.ts: the
// 100 most recent reviews + render-safe media tiles. Read-only (clients author
// reviews); the pro may only feature media in their portfolio (web-only here).

/// `GET /api/v1/pro/reviews` → `{ ok, items }` (envelope's `ok` ignored).
public struct ProReviewsListResponse: Decodable, Sendable {
    public let items: [ProReviewItem]
}

public struct ProReviewItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let rating: Int
    public let headline: String?
    public let body: String?
    public let bookingId: String?
    public let createdAtISO: String
    public let date: String
    public let clientName: String
    public let clientHref: String?
    public let mediaTiles: [MediaTile]

    public struct MediaTile: Decodable, Sendable, Identifiable {
        public let id: String
        public let caption: String?
        public let isVideo: Bool
        public let isFeaturedInPortfolio: Bool
        public let services: [ServiceTag]
        /// Render-safe (signed) thumbnail/source URL.
        public let src: String

        public struct ServiceTag: Decodable, Sendable, Identifiable {
            public let id: String
            public let serviceName: String
        }
    }
}
