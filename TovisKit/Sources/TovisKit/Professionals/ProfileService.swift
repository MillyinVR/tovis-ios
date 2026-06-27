import Foundation

/// Reads a public professional profile (`GET /api/v1/professionals/{id}`) — the
/// same eager full-profile load the web profile page uses (header + stats +
/// offerings + portfolio + reviews). A pending-verification or missing pro
/// returns 404, which surfaces as `APIError.server(status: 404, …)`.
public final class ProfileService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// Fetch a pro's public profile by professional id.
    public func professional(id: String) async throws -> ProProfile {
        let response: ProProfileResponse = try await api.request("/professionals/\(id)")
        return response.professional
    }
}