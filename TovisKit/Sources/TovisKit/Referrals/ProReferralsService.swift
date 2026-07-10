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

    /// GET /api/v1/pro/settings/referral-rewards → the pro's referral-REWARD config
    /// (enable flag + tier + discount/credit values). The route falls back to a
    /// disabled RECOGNITION default server-side when the pro has no payment-settings
    /// row yet, so this never 404s for an authed pro.
    public func rewardSettings() async throws -> ProReferralRewardSettings {
        let response: ProReferralRewardSettingsResponse =
            try await api.request("/pro/settings/referral-rewards")
        return response.settings
    }

    /// PATCH /api/v1/pro/settings/referral-rewards → save a partial config change and
    /// return the server's canonical settings. Only the patch's non-nil fields are
    /// sent, so the discount and credit values persist independently (like the web
    /// editor, which saves only the field it edited). See the wire-asymmetry note on
    /// `ProReferralRewardSettings`: the Decimal credit comes back as a string but must
    /// go out as a number, which `ProReferralRewardSettingsPatch` handles.
    @discardableResult
    public func updateRewardSettings(
        _ patch: ProReferralRewardSettingsPatch
    ) async throws -> ProReferralRewardSettings {
        let body = try JSONEncoder.canonical.encode(patch)
        let response: ProReferralRewardSettingsResponse = try await api.request(
            "/pro/settings/referral-rewards",
            method: .patch,
            body: body
        )
        return response.settings
    }
}
