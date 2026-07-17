import Foundation

// Wire models for Discover — GET /api/v1/search/pros (the geo pro search the web
// SearchMapClient uses) + GET /api/v1/discover/categories. Mirrors
// lib/search/contracts.ts (SearchProItemDto / SearchProLocationPreviewDto) and
// lib/discovery/categoryTypes.ts. Coordinates are coarsened (~neighborhood) on
// the wire for privacy; distanceMiles is accurate. Only the rendered subset is
// modeled; unknown keys are ignored.

// MARK: - GET /api/v1/search/pros

struct SearchProsResponse: Decodable, Sendable {
    let items: [SearchProItem]
    let nextCursor: String?
}

public struct SearchProItem: Decodable, Sendable, Identifiable {
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
    public let closestLocation: SearchProLocation?
    public let primaryLocation: SearchProLocation?

    /// The location to plot: the one closest to the search origin, else primary.
    public var mapLocation: SearchProLocation? { closestLocation ?? primaryLocation }
}

public struct SearchProLocation: Decodable, Sendable, Identifiable {
    public let id: String
    public let formattedAddress: String?
    public let city: String?
    public let state: String?
    public let timeZone: String?
    public let placeId: String?
    public let lat: Double?
    public let lng: Double?
    public let isPrimary: Bool

    /// A short "City, ST" label.
    public var cityState: String? {
        switch (city, state) {
        case let (c?, s?): return "\(c), \(s)"
        case let (c?, nil): return c
        case let (nil, s?): return s
        default: return nil
        }
    }
}

// MARK: - GET /api/v1/search/services

struct SearchServicesResponse: Decodable, Sendable {
    let items: [SearchServiceItem]
    let nextCursor: String?
}

/// One row of the service catalog (`SearchServiceItemDto`). Deliberately thin —
/// the route selects only `id`, `name` and the category, so there is **no price,
/// pro, image or count** to render. That is why a picked service hands off to
/// `searchPros(serviceId:)` rather than trying to stand on its own.
public struct SearchServiceItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let categoryId: String?
    public let categoryName: String?
    public let categorySlug: String?
}

// MARK: - GET /api/v1/discover/categories

struct DiscoverCategoriesResponse: Decodable, Sendable {
    let categories: [DiscoverCategory]
}

public struct DiscoverCategory: Decodable, Sendable, Hashable {
    public let kind: String        // "ALL" | "SERVICE_CATEGORY"
    public let id: String?         // null for ALL
    public let label: String
    public let slug: String

    /// Stable identity for ForEach (slug is unique; ALL has a null id).
    public var identity: String { id ?? "all" }
    public var isAll: Bool { kind == "ALL" }
}

// MARK: - GET /api/v1/discover/trending-tags

struct TrendingTagsResponse: Decodable, Sendable {
    let tags: [TrendingTag]
}

/// A windowed most-used look tag for the Discover surface (social-first D2).
/// `slug` is the URL key for the web tag page (/looks/tags/{slug}); `display` is
/// the label; `lookCount` is feed-visible looks carrying it in the window.
/// Mirrors `TrendingTagDto` (lib/discovery/trendingTags.ts).
public struct TrendingTag: Decodable, Sendable, Identifiable, Hashable {
    public let slug: String
    public let display: String
    public let lookCount: Int
    public var id: String { slug }
}
