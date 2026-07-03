import Foundation

/// Client referrals — the digital invite link that credits sign-ups to this
/// client exactly like a tap on their physical card (same TapIntent spine).
/// Backs the web /client/referrals InviteLinkCard. Authenticated; CLIENT-only.
public final class ReferralsService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/client/referrals/invite-link → the client's shareable
    /// invite link (the server mints their CLIENT_REFERRAL card on first use).
    public func inviteLink() async throws -> ClientInviteLink {
        try await api.request("/client/referrals/invite-link")
    }
}
