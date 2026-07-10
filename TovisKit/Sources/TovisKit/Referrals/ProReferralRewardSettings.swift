import Foundation

/// Referral-REWARD configuration for the authed pro — the web
/// `/pro/referral-rewards` settings editor (`ReferralRewardsClient`): the master
/// on/off, the reward tier, and the discount / credit values. Decoded from
/// `GET /api/v1/pro/settings/referral-rewards` → `{ ok, settings }` and echoed back
/// from the `PATCH`. Distinct from `ProReferralActivity` (the read-only
/// who-referred-whom feed on the same web page). iOS-only port — the routes exist.
///
/// ⚠️ **Wire asymmetry.** The route persists `referralCreditAmount` as a Prisma
/// `Decimal`, which serializes to a JSON **string** (`"12.5"`) on the way *out*, but
/// the `PATCH` validator requires a JSON **number** on the way *in*. So we decode a
/// string here and encode a number in `ProReferralRewardSettingsPatch`.
public struct ProReferralRewardSettings: Decodable, Sendable {
    /// Master switch — when false no reward is granted, whatever the tier.
    public let enabled: Bool
    /// `RECOGNITION` | `DISCOUNT` | `CREDIT`, kept raw (the `ProReferralActivity`
    /// idiom — the view switches on it and treats anything else as recognition).
    public let tier: String
    /// Percent off the referrer's next booking — DISCOUNT tier only, 1–100.
    public let discountPercent: Int?
    /// Dollar credit on the referrer's next booking — CREDIT tier only, > 0.
    /// Parsed from the wire's Decimal string.
    public let creditAmount: Double?

    private enum CodingKeys: String, CodingKey {
        case referralRewardEnabled
        case referralRewardTier
        case referralDiscountPercent
        case referralCreditAmount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .referralRewardEnabled) ?? false
        tier = try c.decodeIfPresent(String.self, forKey: .referralRewardTier) ?? "RECOGNITION"
        discountPercent = try c.decodeIfPresent(Int.self, forKey: .referralDiscountPercent)
        creditAmount = Self.decodeMoney(c, .referralCreditAmount)
    }

    /// `referralCreditAmount` arrives as a Decimal **string** (or null). Be lenient
    /// and also accept a bare number, so a future contract tweak can't break decode.
    private static func decodeMoney(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> Double? {
        if let raw = try? c.decodeIfPresent(String.self, forKey: key) {
            return Double(raw)
        }
        if let n = try? c.decodeIfPresent(Double.self, forKey: key) {
            return n
        }
        return nil
    }

    /// Memberwise init for tests / previews / optimistic view state.
    public init(enabled: Bool, tier: String, discountPercent: Int?, creditAmount: Double?) {
        self.enabled = enabled
        self.tier = tier
        self.discountPercent = discountPercent
        self.creditAmount = creditAmount
    }
}

/// `{ ok, settings }` envelope — the shape of both the GET and the PATCH response.
public struct ProReferralRewardSettingsResponse: Decodable, Sendable {
    public let settings: ProReferralRewardSettings
}

/// A **partial** PATCH body for `PATCH /api/v1/pro/settings/referral-rewards`. Only
/// the non-nil fields are sent (Swift omits nil optionals), so a caller updates
/// exactly the columns it means to — mirroring the web page, which saves only the
/// field it edited and leaves the others' stored values untouched. Property names
/// are the raw request keys the route reads. `referralCreditAmount` is a JSON
/// **number** here (the route rejects a string), unlike the GET's Decimal string.
public struct ProReferralRewardSettingsPatch: Encodable, Sendable {
    public var referralRewardEnabled: Bool?
    public var referralRewardTier: String?
    public var referralDiscountPercent: Int?
    public var referralCreditAmount: Double?

    public init(
        enabled: Bool? = nil,
        tier: String? = nil,
        discountPercent: Int? = nil,
        creditAmount: Double? = nil
    ) {
        self.referralRewardEnabled = enabled
        self.referralRewardTier = tier
        self.referralDiscountPercent = discountPercent
        self.referralCreditAmount = creditAmount
    }
}
