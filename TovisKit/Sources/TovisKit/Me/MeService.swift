import Foundation

/// Reads the client "Me" dashboard — the single backend source the web
/// /client/me page also renders (`GET /api/v1/me`). Authenticated (bearer
/// token); the caller must be signed in as a CLIENT or the backend returns 403.
public final class MeService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/me → the Me payload (unwrapped from the envelope).
    public func fetch() async throws -> ClientMe {
        let response: ClientMeResponse = try await api.request("/me")
        return response.me
    }
}