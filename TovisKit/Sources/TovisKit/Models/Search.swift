import Foundation

// Wire models for Discover/search — GET /api/v1/search?tab=PROS|SERVICES&q=…
// Mirrors lib/search/contracts.ts (SearchProItemDto / SearchServiceItemDto) and
// the unified route's `{ pros, services }` envelope. Only the rendered subset is
// modeled; nullable fields are optionals; unknown keys ignored.

/// Envelope for `GET /api/v1/search` → `{ ok, pros, services }`.
struct SearchResponse: Decodable, Sendable {
    let pros: [SearchPro]
    let services: [SearchServiceItem]
}

public struct SearchPro: Decodable, Sendable, Identifiable {
    public let id: String
    public let businessName: String?
    /// Pre-resolved public display name (honors the pro's nameDisplay preference).
    public let displayName: String
    public let handle: String?
    public let professionType: String?
    public let avatarUrl: String?
    public let locationLabel: String?
    public let distanceMiles: Double?
    public let ratingAvg: Double?
    public let ratingCount: Int
    public let minPrice: Double?
    public let supportsMobile: Bool
}

public struct SearchServiceItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let categoryId: String?
    public let categoryName: String?
    public let categorySlug: String?
}