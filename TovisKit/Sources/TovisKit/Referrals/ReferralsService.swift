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

    /// GET /api/v1/client/referrals → the friends this client has referred,
    /// newest first (the server caps at 50). Each carries its lifecycle status
    /// and any reward it earned. Backs the web `/client/referrals` list.
    public func list() async throws -> [ClientReferral] {
        let response: ClientReferralListResponse = try await api.request("/client/referrals")
        return response.referrals
    }

    /// POST /api/v1/client/referrals/{id}/confirm — the client vouches for a
    /// pending referral (they recognize the friend). No body; the route rejects
    /// a non-pending / expired / not-yours referral as an `APIError` (409/410/403).
    public func confirm(id: String) async throws {
        try await api.requestVoid("/client/referrals/\(id)/confirm", method: .post)
    }

    /// POST /api/v1/client/referrals/{id}/decline — dismiss a pending referral.
    /// No body; same ownership/status guards as `confirm`.
    public func decline(id: String) async throws {
        try await api.requestVoid("/client/referrals/\(id)/decline", method: .post)
    }
}
