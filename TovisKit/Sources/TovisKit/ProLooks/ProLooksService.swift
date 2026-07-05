import Foundation

/// PRO workspace — read-only creator analytics for the pro's own Looks ("Your
/// Looks performance", web pro-dashboard C1). Authenticated; PRO-only.
public final class ProLooksService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/looks/analytics → per-look engagement + follower growth + top looks.
    public func analytics() async throws -> ProLooksAnalytics {
        let response: ProLooksAnalyticsResponse = try await api.request("/pro/looks/analytics")
        return response.analytics
    }
}
