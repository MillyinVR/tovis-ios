import Foundation

/// The authed pro's current membership (web `/pro/membership` status).
/// Decoded from `GET /api/v1/pro/membership/status` → `{ ok, membership }`.
/// A pro with no subscription row reads as the free plan.
public struct ProMembership: Decodable, Sendable {
    /// Effective plan after comp/lapse resolution: `free` | `pro` | `premium` | `studio`.
    public let planKey: String
    /// The raw purchased plan before comp/lapse resolution.
    public let rawPlanKey: String
    /// Stripe subscription status (e.g. `active`, `trialing`, `past_due`) or nil.
    public let status: String?
    /// A comped plan granted by an admin, if any, and until when (ISO-8601).
    public let compPlanKey: String?
    public let compUntil: String?
    /// Boolean entitlements unlocked by the effective plan (see PLAN_ENTITLEMENTS).
    public let entitlements: [String]
    /// Whether this pro's social exports drop the small platform mark, leaving
    /// only their own signature. Resolved SERVER-side
    /// (tovis-app lib/pro/socialExportMark.ts) rather than re-derived here from
    /// `entitlements`, the same way the finance payload ships `canExportTaxDocs` —
    /// the render happens on the device, the decision does not.
    ///
    /// Optional so a backend older than the field still decodes; `nil` means
    /// "unbranded" (`SocialExportPolicy.dropsPlatformMark`), which is also what
    /// every server answers while ENABLE_MEMBERSHIP_ENFORCEMENT is off.
    public let exportsUnbranded: Bool?
    /// Renewal / trial dates (ISO-8601) and billing flags.
    public let currentPeriodEnd: String?
    public let cancelAtPeriodEnd: Bool
    public let trialEndsAt: String?
    public let hasBillingAccount: Bool
}

struct ProMembershipResponse: Decodable, Sendable {
    let membership: ProMembership
}
