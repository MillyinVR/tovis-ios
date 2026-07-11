import Foundation

/// The client account-settings surface — the native counterpart of the web
/// Settings → Profile card (app/client/(gated)/settings/ClientProfileSettings.tsx),
/// backed by `GET`/`PATCH /api/v1/client/settings`. Authenticated (bearer token);
/// the caller must be signed in as a CLIENT or the backend returns 403.
///
/// This carries the richer identity fields the Me dashboard (`GET /api/v1/me`,
/// `MeService`) does not — namely `phone` and `dateOfBirth` — so the edit screen
/// loads from here rather than from `/me`.
public final class ClientSettingsService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/client/settings → the editable profile (unwrapped).
    public func profile() async throws -> ClientSettingsProfile {
        let response: ClientSettingsResponse = try await api.request("/client/settings")
        return response.profile
    }

    /// PATCH /api/v1/client/settings — save the profile and return the fresh copy.
    /// All five fields are sent every time (matching the web form); pass `nil` on a
    /// nullable field to CLEAR it (encoded as an explicit JSON `null`). `dateOfBirth`
    /// is a date-only `YYYY-MM-DD` string; the backend 400s any other shape.
    public func updateProfile(
        firstName: String,
        lastName: String,
        phone: String?,
        avatarUrl: String?,
        dateOfBirth: String?
    ) async throws -> ClientSettingsProfile {
        let payload = try JSONEncoder.canonical.encode(ClientProfileUpdateRequest(
            firstName: firstName,
            lastName: lastName,
            phone: phone,
            avatarUrl: avatarUrl,
            dateOfBirth: dateOfBirth
        ))
        let response: ClientSettingsResponse = try await api.request(
            "/client/settings",
            method: .patch,
            body: payload
        )
        return response.profile
    }
}
