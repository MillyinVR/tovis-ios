import Foundation

/// PRO workspace — weekly working hours (web `/pro/calendar` working-hours form).
/// Reads the resolved week and saves edits. Authenticated; PRO-only.
/// See docs/PRO-BACKEND-CONTRACTS.md.
public final class ProScheduleService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/last-minute/workspace — the last-minute settings (master
    /// toggle, priority offer, tiers, per-day disables) + service rules + blocks +
    /// active offerings (web `/pro/last-minute`).
    public func lastMinuteWorkspace() async throws -> ProLastMinuteWorkspace {
        return try await api.request("/pro/last-minute/workspace")
    }

    /// GET /api/v1/pro/working-hours — the saved (or default) week for a location
    /// type. `locationType` is "SALON" or "MOBILE".
    public func workingHours(
        locationType: String? = nil,
        locationId: String? = nil
    ) async throws -> ProWorkingHoursResponse {
        var query: [URLQueryItem] = []
        if let locationType { query.append(URLQueryItem(name: "locationType", value: locationType)) }
        if let locationId { query.append(URLQueryItem(name: "locationId", value: locationId)) }
        return try await api.request("/pro/working-hours", query: query.isEmpty ? nil : query)
    }

    /// POST /api/v1/pro/working-hours — persist the week. Returns the saved result.
    @discardableResult
    public func updateWorkingHours(
        _ week: ProWeekHours,
        locationType: String? = nil,
        locationId: String? = nil
    ) async throws -> ProWorkingHoursResponse {
        var query: [URLQueryItem] = []
        if let locationType { query.append(URLQueryItem(name: "locationType", value: locationType)) }
        if let locationId { query.append(URLQueryItem(name: "locationId", value: locationId)) }
        let body = try JSONEncoder.canonical.encode(ProWorkingHoursUpdateRequest(workingHours: week))
        return try await api.request(
            "/pro/working-hours",
            method: .post,
            query: query.isEmpty ? nil : query,
            body: body
        )
    }
}
