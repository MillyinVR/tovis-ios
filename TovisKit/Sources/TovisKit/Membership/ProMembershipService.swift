import Foundation

/// PRO workspace — read-only membership status (plan tier + entitlements). The
/// native display counterpart to the web `/pro/membership` page. Purchasing is
/// intentionally NOT offered in-app (Apple IAP); this is status only.
/// Authenticated; PRO-only.
public final class ProMembershipService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/membership/status → the pro's effective plan + entitlements.
    public func status() async throws -> ProMembership {
        let response: ProMembershipResponse = try await api.request("/pro/membership/status")
        return response.membership
    }
}
