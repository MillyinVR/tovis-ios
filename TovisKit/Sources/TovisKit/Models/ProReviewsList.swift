import Foundation

// Wire models for the PRO reviews list — GET /api/v1/pro/reviews (tovis-app
// PR #438). Mirrors `ProReviewListItem` from lib/pro/loadProReviewsList.ts: the
// 100 most recent reviews + render-safe media tiles. Clients author reviews;
// the pro may post one public reply per review (PR #475) and may only feature
// media in their portfolio on the web.

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
    /// The pro's public response to this review (tovis-app PR #475), if any.
    public let proReply: ProReviewReply?
    public let mediaTiles: [MediaTile]

    public struct ProReviewReply: Decodable, Sendable {
        public let body: String
        public let repliedAtISO: String
    }

    public struct MediaTile: Decodable, Sendable, Identifiable {
        public let id: String
        public let caption: String?
        public let isVideo: Bool
        public let isFeaturedInPortfolio: Bool
        public let services: [ServiceTag]
        /// Render-safe (signed) thumbnail/source URL.
        public let src: String
        /// Opt-in before/after pairing → this after tile renders as the slider.
        public let before: PairedBeforeMedia?

        public struct ServiceTag: Decodable, Sendable, Identifiable {
            public let id: String
            public let serviceName: String
        }
    }
}

/// `PUT /api/v1/pro/reviews/{id}/reply` → `{ ok, reviewId, reply }`.
public struct ProReviewReplyResponse: Decodable, Sendable {
    public let reviewId: String
    public let reply: ProReviewItem.ProReviewReply
}
