import Foundation

/// The public creator surface, addressed by a client's public **handle** — the
/// native counterpart of the web `/u/[handle]` page. Distinct from the pro chart's
/// by-clientId `ProClientsService.publicProfile` (both render the identical
/// `loadPublicClientProfile` data), so it reuses the same `ProClientPublicProfile`
/// wire model rather than redeclaring the shape (house rule: no duplicate logic).
///
/// - `profile(handle:)` → GET /api/v1/u/{handle}. Unlike the pro route (which
///   answers `profile: null`), the handle route answers **404** when the handle
///   doesn't resolve or the client hasn't opted into a public profile — the two
///   are indistinguishable by design, so this surfaces both as `nil` (a plain
///   "not found" empty state, not an error). The route is public-read and not
///   flag-gated, so a 404 always means "no such public profile", never "not
///   deployed".
/// - `toggleFollow(handle:)` → POST /api/v1/client/follow/{handle}. The route is a
///   toggle (no desired-state body); it returns the authoritative
///   `{ following, followerCount }`. Only a signed-in CLIENT may follow — a
///   pro/guest caller gets 401/403 (the caller degrades gracefully).
public final class PublicClientService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// Loads a client's public creator profile by handle. Returns `nil` when the
    /// handle doesn't resolve or isn't public (route 404).
    public func profile(handle: String) async throws -> ProClientPublicProfile? {
        do {
            let response: ProClientPublicProfileResponse =
                try await api.request("/u/\(handle)")
            return response.profile
        } catch let error as APIError {
            if case let .server(status, _, _) = error, status == 404 {
                return nil
            }
            throw error
        }
    }

    /// Toggles the signed-in client's follow on the target handle and returns the
    /// authoritative follow state. The route ignores the request body (it toggles),
    /// but native still sends `{}` so a Content-Type is set.
    public func toggleFollow(handle: String) async throws -> FollowState {
        try await api.request(
            "/client/follow/\(handle)",
            method: .post,
            body: Data("{}".utf8)
        )
    }
}
