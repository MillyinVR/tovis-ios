import Foundation

/// PRO workspace — read-only referral activity (who-referred-whom + conversion /
/// reward state for referrals credited to this pro). The pro-facing counterpart
/// to the client-side `ReferralsService.inviteLink()`. Authenticated; PRO-only.
public final class ProReferralsService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/referrals → referrals credited to this pro (summary + rows).
    public func activity() async throws -> ProReferralActivity {
        try await api.request("/pro/referrals")
    }
}
