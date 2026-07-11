import Foundation

/// The signed-in client's OWN public-creator identity — the native counterpart of
/// the web Settings → Public profile card
/// (app/client/(gated)/settings/ClientPublicProfileSettings.tsx), backed by
/// `GET`/`PATCH /api/v1/client/profile`. Authenticated (bearer token); the caller
/// must be signed in as a CLIENT or the backend returns 403.
///
/// Not to be confused with `PublicClientService` (which reads SOMEONE ELSE's public
/// profile at `/u/{handle}`). This one edits the owner's handle, public toggle, and
/// bio — the identity that powers that `/u/{handle}` page.
public final class ClientPublicProfileService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/client/profile → the editable public-creator identity (unwrapped).
    public func profile() async throws -> ClientPublicProfileSettings {
        let response: ClientPublicProfileResponse = try await api.request("/client/profile")
        return response.profile
    }

    /// PATCH /api/v1/client/profile — save handle / public toggle / bio and return the
    /// fresh copy. Mirrors the web form: all three keys are sent every time. An empty
    /// `handle`/`publicBio` string CLEARS that field server-side (this route clears via
    /// an empty string, not an explicit null). Going public with no handle is rejected
    /// by the backend (400) and surfaced to the caller as an `APIError`.
    public func updateProfile(
        handle: String,
        isPublicProfile: Bool,
        publicBio: String
    ) async throws -> ClientPublicProfileSettings {
        let payload = try JSONEncoder.canonical.encode(ClientPublicProfileUpdateRequest(
            handle: handle,
            isPublicProfile: isPublicProfile,
            publicBio: publicBio
        ))
        let response: ClientPublicProfileResponse = try await api.request(
            "/client/profile",
            method: .patch,
            body: payload
        )
        return response.profile
    }
}
