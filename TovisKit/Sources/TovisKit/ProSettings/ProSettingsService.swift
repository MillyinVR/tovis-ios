import Foundation

/// PRO workspace — account-level policy settings that were Phase-2 web features:
/// appointment-reminder cadence + no-show / late-cancel fees. Authenticated;
/// PRO-only. The no-show endpoints 404 while `ENABLE_NO_SHOW_PROTECTION` is off.
public final class ProSettingsService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    // MARK: - Appointment reminders (not flag-gated)

    /// GET /api/v1/pro/reminder-settings → the cadence + the server-driven menu.
    public func reminderSettings() async throws -> ProReminderSettingsResponse {
        try await api.request("/pro/reminder-settings")
    }

    /// PUT /api/v1/pro/reminder-settings → save the cadence.
    @discardableResult
    public func updateReminderSettings(enabled: Bool, offsetDays: [Int]) async throws -> ProReminderSettingsResponse {
        let body = try JSONEncoder().encode(ProReminderSettingsUpdate(enabled: enabled, offsetDays: offsetDays))
        return try await api.request("/pro/reminder-settings", method: .put, body: body)
    }

    // MARK: - No-show / late-cancel fees (dark unless ENABLE_NO_SHOW_PROTECTION)

    /// GET /api/v1/pro/no-show-settings → the fee policy. Throws
    /// `APIError.server(404,…)` while the feature flag is off.
    public func noShowSettings() async throws -> ProNoShowSettings {
        let response: ProNoShowSettingsResponse = try await api.request("/pro/no-show-settings")
        return response.settings
    }

    /// PUT /api/v1/pro/no-show-settings → save the fee policy.
    @discardableResult
    public func updateNoShowSettings(_ update: ProNoShowSettingsUpdate) async throws -> ProNoShowSettings {
        let body = try JSONEncoder().encode(update)
        let response: ProNoShowSettingsResponse = try await api.request(
            "/pro/no-show-settings", method: .put, body: body
        )
        return response.settings
    }
}
