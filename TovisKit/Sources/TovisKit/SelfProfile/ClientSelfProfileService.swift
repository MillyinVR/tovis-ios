import Foundation

/// The client's personalization self-profile — the native counterpart of the web
/// Settings → "Get better matches" card
/// (app/client/(gated)/settings/ClientSelfProfileSettings.tsx), backed by
/// `GET`/`PATCH /api/v1/client/self-profile`. Authenticated (bearer token); a non-client
/// token 403s.
///
/// Everything it carries is explicit + user-entered (spec §6.6): hair type/length/color,
/// skin type/concern, and declared category interests. The server
/// (lib/personalization/selfProfile.ts) is the SSOT validator — this service only shuttles
/// values to and from it, never validating locally.
public final class ClientSelfProfileService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/client/self-profile → the stored profile, or nil when the client
    /// hasn't entered anything yet (the route returns `selfProfile: null`).
    public func profile() async throws -> ClientSelfProfile? {
        let response: ClientSelfProfileResponse = try await api.request("/client/self-profile")
        return response.selfProfile
    }

    /// PATCH /api/v1/client/self-profile — save the whole self-profile and return the
    /// fresh copy (nil when everything is cleared). Mirrors the web form: every field
    /// key is sent each time (a field absent from `fields` clears it via an explicit JSON
    /// null) and `interests` is sent as a full array (an empty array clears them all).
    /// An invalid option value is rejected by the backend (400
    /// INVALID_SELF_PROFILE_FIELD) and surfaced to the caller as an `APIError`.
    public func update(
        fields: [SelfProfileFieldKey: String],
        interests: [String]
    ) async throws -> ClientSelfProfile? {
        let payload = try JSONEncoder.canonical.encode(
            ClientSelfProfileUpdateRequest(fields: fields, interests: interests)
        )
        let response: ClientSelfProfileResponse = try await api.request(
            "/client/self-profile",
            method: .patch,
            body: payload
        )
        return response.selfProfile
    }
}
