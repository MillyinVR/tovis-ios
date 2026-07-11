import Foundation

/// A referral this client has sent out — a friend who tapped their invite link
/// (or physical card) and, once they book, the pro + reward it earned. Decoded
/// from `GET /api/v1/client/referrals` → `{ ok, referrals: [...] }`.
///
/// Mirrors the inline `Referral` shape in web
/// `app/client/(gated)/referrals/ReferralListClient.tsx`. There is no shared
/// `lib/dto` for the list (the invite link has one — `ClientInviteLink` — but
/// the list is defined inline route-side), so this is the wire contract.
public struct ClientReferral: Decodable, Sendable, Identifiable {
    public let id: String
    /// Lifecycle status: `PENDING` | `CONFIRMED` | `CONVERTED` | `REWARDED` |
    /// `DECLINED` | `EXPIRED`. Kept a raw string per the server-driven-labels
    /// convention (a new backend status never fails decoding). The server maps
    /// an expired-but-still-PENDING referral to `EXPIRED` before sending.
    public let status: String
    /// The friend's first name (the server falls back to "Someone").
    public let referredFirstName: String
    public let referredAvatarUrl: String?
    /// The pro the friend booked with, once the referral converts (else nil).
    public let proName: String?
    /// Root-relative pro-profile href; nil until the referral converts.
    public let proHref: String?
    /// Reward tier: `RECOGNITION` | `DISCOUNT` | `CREDIT` | nil.
    public let rewardTier: String?
    /// Percent (DISCOUNT) or dollars (CREDIT); nil for RECOGNITION / no reward.
    public let rewardValue: Double?
    public let rewardAppliedAt: String?
    public let confirmedAt: String?
    public let convertedAt: String?
    public let expiresAt: String
    public let createdAt: String

    /// The client can vouch for / dismiss a referral only while it's still pending.
    public var isPending: Bool { status == "PENDING" }
}

/// `{ ok, referrals: [...] }` envelope for `GET /api/v1/client/referrals`.
struct ClientReferralListResponse: Decodable, Sendable {
    let referrals: [ClientReferral]
}
