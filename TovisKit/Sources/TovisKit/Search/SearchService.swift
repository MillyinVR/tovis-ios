import Foundation

/// Discover/search — the same endpoint the web /search surface uses
/// (`GET /api/v1/search`). The unified route returns pros OR services per the
/// `tab` param; an empty query returns a default browse list.
public final class SearchService: Sendable {
    public enum Tab: String, Sendable { case pros = "PROS", services = "SERVICES" }

    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/search?tab=PROS&q=… → matching pros.
    public func pros(query: String) async throws -> [SearchPro] {
        try await search(tab: .pros, query: query).pros
    }

    /// GET /api/v1/search?tab=SERVICES&q=… → matching services.
    public func services(query: String) async throws -> [SearchServiceItem] {
        try await search(tab: .services, query: query).services
    }

    private func search(tab: Tab, query: String) async throws -> SearchResponse {
        var items = [URLQueryItem(name: "tab", value: tab.rawValue)]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "q", value: trimmed)) }
        return try await api.request("/search", query: items)
    }
}