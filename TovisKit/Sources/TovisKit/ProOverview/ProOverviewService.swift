import Foundation

/// PRO workspace — the Overview / dashboard monthly analytics (web
/// `/pro/dashboard`, GET /api/v1/pro/overview, tovis-app PR #437). Authenticated;
/// PRO-only (CLIENT tokens 403).
public final class ProOverviewService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/overview?month= → the monthly analytics view-model. Pass
    /// nil for the current month, or a "YYYY-MM" key to select a month.
    public func overview(month: String? = nil) async throws -> ProOverviewResponse {
        let query = month.map { [URLQueryItem(name: "month", value: $0)] }
        return try await api.request("/pro/overview", query: query)
    }
}
