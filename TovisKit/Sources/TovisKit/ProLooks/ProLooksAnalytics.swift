import Foundation

/// "Your Looks performance" — per-look engagement + follower growth + top looks
/// for the authed pro (web pro-dashboard C1 parity). Decoded from
/// `GET /api/v1/pro/looks/analytics` → `{ ok, analytics }`.
public struct ProLooksAnalytics: Decodable, Sendable {
    public let publishedCount: Int
    public let totals: Totals
    public let followers: FollowerGrowth
    public let topLooks: [LookStats]

    public struct Totals: Decodable, Sendable {
        public let views: Int
        public let likes: Int
        public let comments: Int
        public let saves: Int
        public let shares: Int
        public let bookings: Int
    }

    /// One trailing week of new followers; `weeksAgo` 0 = this (partial) week.
    public struct FollowerBucket: Decodable, Sendable, Identifiable {
        public let weeksAgo: Int
        public let count: Int
        public var id: Int { weeksAgo }
    }

    public struct FollowerGrowth: Decodable, Sendable {
        public let total: Int
        public let new30d: Int
        public let weekly: [FollowerBucket]
    }

    public struct LookStats: Decodable, Sendable, Identifiable {
        public let lookPostId: String
        public let caption: String?
        public let thumbUrl: String?
        public let publishedAt: String?
        public let views: Int
        public let likes: Int
        public let comments: Int
        public let saves: Int
        public let shares: Int
        public let bookings: Int
        /// Display heuristic used to order "top-performing" — not a stored field.
        public let engagementScore: Double
        public var id: String { lookPostId }
    }
}

struct ProLooksAnalyticsResponse: Decodable, Sendable {
    let analytics: ProLooksAnalytics
}
