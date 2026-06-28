import Foundation

/// Reads the client home screen — the single backend source the web home page
/// also uses (`GET /api/v1/client/home`). Authenticated (bearer token); the
/// caller must be signed in as a CLIENT or the backend returns 403.
public final class HomeService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/client/home → the home payload (unwrapped from the envelope).
    public func fetch() async throws -> ClientHome {
        let response: ClientHomeResponse = try await api.request("/client/home")
        return response.home
    }

    /// Accept a last-minute (priority) offer. `recipientId` is `HomeInvite.id`.
    /// A 410 (expired / opening inactive) or 409 (no longer priority) surfaces as
    /// `APIError.server`.
    public func acceptInvite(recipientId: String) async throws {
        try await api.requestVoid(
            "/client/priority-offer/\(recipientId)/accept",
            method: .post
        )
    }

    /// Decline a last-minute (priority) offer. `recipientId` is `HomeInvite.id`.
    public func declineInvite(recipientId: String) async throws {
        try await api.requestVoid(
            "/client/priority-offer/\(recipientId)/decline",
            method: .post
        )
    }
}
