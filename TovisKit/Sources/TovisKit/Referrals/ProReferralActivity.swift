import Foundation

/// Referrals credited to the authed pro (web `/pro/referral-rewards` viewer,
/// tovis-app PR #500). Decoded from `GET /api/v1/pro/referrals` →
/// `{ ok, summary, rows }`. Scoped to `Referral.professionalId` (set only at
/// conversion), so every row is at least CONVERTED — pending client↔client
/// referrals never surface.
public struct ProReferralActivity: Decodable, Sendable {
    public let summary: Summary
    public let rows: [Row]

    public struct Summary: Decodable, Sendable {
        /// Referrals that converted into a booking with this pro.
        public let total: Int
        /// Of those, how many have had their reward applied to a later booking.
        public let rewarded: Int
        /// Dollar credits actually applied (CREDIT tier only; DISCOUNT is a percent).
        public let creditDollarsApplied: Double
    }

    public struct Row: Decodable, Sendable, Identifiable {
        public let id: String
        /// Referral lifecycle status (e.g. `CONVERTED`, `REWARDED`).
        public let status: String
        public let createdAt: String
        public let convertedAt: String?
        /// `CREDIT` | `DISCOUNT` | nil.
        public let rewardTier: String?
        public let rewardValue: Double?
        public let rewardApplied: Bool
        /// First names only (the pro's own contacts).
        public let referrerName: String
        public let referredName: String
        public let cardShortCode: String?
    }
}
