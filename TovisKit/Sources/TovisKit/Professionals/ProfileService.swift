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

    /// Favorite (POST) or unfavorite (DELETE) a pro. Returns the new favorited
    /// state + total favorite count.
    @discardableResult
    public func setFavorite(professionalId: String, favorited: Bool) async throws -> FavoriteResult {
        try await api.request(
            "/professionals/\(professionalId)/favorite",
            method: favorited ? .post : .delete
        )
    }

    /// Save (POST) or unsave (DELETE) one of the pro's services for the current
    /// client. Returns the new saved state + total save count. Client-only — a
    /// guest gets `APIError.server(401, …)` (the caller should route to login).
    @discardableResult
    public func setServiceFavorite(serviceId: String, favorited: Bool) async throws -> FavoriteResult {
        try await api.request(
            "/services/\(serviceId)/favorite",
            method: favorited ? .post : .delete
        )
    }

    /// Mark (POST) or unmark (DELETE) a review as "helpful" for the current
    /// client. Returns the new state + total helpful count. Client-only.
    @discardableResult
    public func setReviewHelpful(reviewId: String, helpful: Bool) async throws -> ReviewHelpfulResult {
        try await api.request(
            "/reviews/\(reviewId)/helpful",
            method: helpful ? .post : .delete
        )
    }
}