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

    /// PATCH /api/v1/pro/last-minute/settings — persist the "Last-minute defaults"
    /// (master toggle, default visibility, floor, tier anchors, priority offer,
    /// per-day disables). The route applies each present key; we send the whole
    /// form. Callers reload `lastMinuteWorkspace()` to reflect the saved state.
    public func updateLastMinuteSettings(_ request: ProLastMinuteSettingsPatchRequest) async throws {
        let body = try JSONEncoder.canonical.encode(request)
        try await api.requestVoid("/pro/last-minute/settings", method: .patch, body: body)
    }

    /// PATCH /api/v1/pro/last-minute/rules — upsert one per-service eligibility
    /// rule. `minCollectedSubtotal` nil inherits the global floor.
    public func updateLastMinuteServiceRule(
        serviceId: String,
        enabled: Bool,
        minCollectedSubtotal: String?
    ) async throws {
        let body = try JSONEncoder.canonical.encode(
            ProLastMinuteServiceRulePatchRequest(
                serviceId: serviceId, enabled: enabled, minCollectedSubtotal: minCollectedSubtotal
            )
        )
        try await api.requestVoid("/pro/last-minute/rules", method: .patch, body: body)
    }

    /// POST /api/v1/pro/last-minute/blocks — block a time range from ever being
    /// offered as a last-minute opening. Instants are ISO-8601 UTC; the server
    /// rejects a window that overlaps an existing block (409, surfaced inline).
    public func addLastMinuteBlock(startAt: String, endAt: String, reason: String?) async throws {
        let body = try JSONEncoder.canonical.encode(
            ProLastMinuteBlockCreateRequest(startAt: startAt, endAt: endAt, reason: reason)
        )
        try await api.requestVoid("/pro/last-minute/blocks", method: .post, body: body)
    }

    /// DELETE /api/v1/pro/last-minute/blocks?id= — remove a blocked range.
    public func deleteLastMinuteBlock(id: String) async throws {
        try await api.requestVoid(
            "/pro/last-minute/blocks",
            method: .delete,
            query: [URLQueryItem(name: "id", value: id)]
        )
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
