import Foundation

/// PRO workspace — read-only "why you're showing up" transparency (web §6.5).
/// Authenticated; PRO-only. The route scopes every read to the authed pro, so
/// there is no professionalId to pass.
public final class ProVisibilityService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/visibility → ranked visibility levers for the authed pro.
    public func health() async throws -> ProVisibilityHealth {
        let response: ProVisibilityResponse = try await api.request("/pro/visibility")
        return response.visibility
    }
}
