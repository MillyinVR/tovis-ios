import Foundation

/// Discover — the geo pro search that backs the web SearchMapClient
/// (`GET /api/v1/search/pros`) plus the category rail
/// (`GET /api/v1/discover/categories`). Results carry coarsened coordinates for
/// map pins and an accurate `distanceMiles`. Public endpoint (works signed-in).
public final class DiscoverService: Sendable {
    public enum Sort: String, Sendable { case distance = "DISTANCE", name = "NAME", rating = "RATING", price = "PRICE" }

    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    public struct ProsPage: Sendable {
        public let items: [SearchProItem]
        public let nextCursor: String?
    }

    /// GET /api/v1/search/pros — pros near (lat,lng) within `radiusMiles`,
    /// optionally filtered by free text, category, mobile-capability, and sorted.
    public func searchPros(
        q: String? = nil,
        lat: Double? = nil,
        lng: Double? = nil,
        radiusMiles: Int = 15,
        categoryId: String? = nil,
        sort: Sort = .distance,
        mobileOnly: Bool = false,
        cursor: String? = nil,
        limit: Int = 50
    ) async throws -> ProsPage {
        var query = [
            URLQueryItem(name: "radiusMiles", value: String(radiusMiles)),
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        let trimmed = q?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { query.append(URLQueryItem(name: "q", value: trimmed)) }
        if let lat { query.append(URLQueryItem(name: "lat", value: String(lat))) }
        if let lng { query.append(URLQueryItem(name: "lng", value: String(lng))) }
        if let categoryId { query.append(URLQueryItem(name: "categoryId", value: categoryId)) }
        if mobileOnly { query.append(URLQueryItem(name: "mobile", value: "1")) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }

        let response: SearchProsResponse = try await api.request("/search/pros", query: query)
        return ProsPage(items: response.items, nextCursor: response.nextCursor)
    }

    /// GET /api/v1/discover/categories — the category rail (leads with "ALL").
    public func categories() async throws -> [DiscoverCategory] {
        let response: DiscoverCategoriesResponse = try await api.request("/discover/categories")
        return response.categories
    }
}
