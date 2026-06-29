import Foundation

/// Reads the PRO calendar — bookings, blocks, and the management buckets
/// (`GET /api/v1/pro/calendar`). Authenticated; PRO-only. The web page renders
/// the same payload server-side; this is the native client's only schedule
/// source (the `/pro/bookings` route is POST-only).
public final class ProCalendarService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/calendar. With no range the server returns its default
    /// window; pass `from`/`to` (ISO-8601) to scope it. `locationId` selects a
    /// specific location when the pro has more than one.
    public func calendar(
        from: String? = nil,
        to: String? = nil,
        locationId: String? = nil
    ) async throws -> ProCalendarResponse {
        var query: [URLQueryItem] = []
        if let from { query.append(URLQueryItem(name: "from", value: from)) }
        if let to { query.append(URLQueryItem(name: "to", value: to)) }
        if let locationId { query.append(URLQueryItem(name: "locationId", value: locationId)) }
        return try await api.request("/pro/calendar", query: query.isEmpty ? nil : query)
    }
}
