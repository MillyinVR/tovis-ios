import Foundation

/// Customer-facing membership copy — the entitlement labels and the commission
/// pitch shown on `ProMembershipView`.
///
/// 🔴 This lives in TovisKit rather than beside the view ON PURPOSE. CI compiles and
/// tests TovisKit; nothing compiles the `Tovis/` app target. Copy that makes a
/// factual claim to a paying pro (what their plan includes, what the platform
/// charges) is exactly the code that must not sit somewhere a mistake goes
/// unnoticed. Mirrors `app/pro/membership/entitlementCopy.ts` on web.
public enum ProMembershipCopy {
    public struct AdvertisedEntitlement: Equatable, Sendable {
        public let key: String
        public let label: String
    }

    /// What a free pro is told an upgrade unlocks.
    ///
    /// Must stay a subset of what the server actually grants AND implements.
    /// `advanced_analytics` was listed here — and on the web upgrade page — with
    /// zero implementation anywhere in either repo; it is kept only because it now
    /// has one (the gated retention section on the web dashboard), with wording
    /// narrowed to what that section actually shows. See
    /// `docs/design/membership-value-brief.md` §5.1.F in tovis-app.
    public static let proPreviewEntitlements = [
        "tax_export", "custom_handle", "advanced_analytics", "priority_discovery",
    ]

    /// Copy for an entitlement key, or nil when we deliberately do NOT advertise it.
    ///
    /// 🔴 Returning nil is the mechanism, not an oversight. The previous version fell
    /// back to title-casing the raw key, which auto-advertised whatever the server
    /// sent — `white_label` rendered as "White Label" to a comped Studio partner even
    /// though nothing implements it. Adding a label here is a promise to the buyer:
    /// only add one once the entitlement has a real implementation call site.
    public static func entitlementLabel(_ key: String) -> String? {
        switch key {
        case "custom_handle": return "Custom handle (name.tovis.me)"
        case "tax_export": return "Tax exports (CSV + Schedule C)"
        // Narrowed from the old bare "Advanced analytics": the surface is on the
        // web dashboard, so the label promises exactly what it delivers.
        case "advanced_analytics":
            return "Retention insights — rebooking rate + who's due back (on the web)"
        case "priority_discovery": return "Priority placement in discovery"
        // 🔴 `discovery_fee_waiver` is deliberately UNLABELED (Tori, 2026-08-04).
        // As coded it waives the CLIENT's fee; the intended perk waives a PRO-side
        // fee that does not exist yet. Nothing honest to advertise — see
        // membership-value-brief.md §8.5 in tovis-app. Do not add a label until
        // that fee ships AND its conversion impact has been measured.
        default: return nil
        }
    }

    /// The entitlements we are willing to name, in the server's order. Unlabeled keys
    /// are dropped rather than rendered blank or auto-titled.
    public static func advertised(_ keys: [String]) -> [AdvertisedEntitlement] {
        keys.compactMap { key in
            guard let label = entitlementLabel(key) else { return nil }
            return AdvertisedEntitlement(key: key, label: label)
        }
    }

    public static let commissionPitchTitle = "Never a commission on your work"

    /// The commission pitch — the strongest true thing about the platform, and it
    /// was nowhere in the membership story (membership-value-brief.md §0.4 / §3.1).
    ///
    /// 🔴 EVERY CLAIM MUST SURVIVE THE PLANNED FEE MODEL (§8.5), not just today's
    /// code. A pro-side fee is coming ($5 flat, once, on a cold match) and the
    /// client fee moves from a flat $5 to 10% of the DEPOSIT. So this copy must
    /// never say "you keep 100%", "0% of deposits", "paid by the client", "a flat
    /// fee", or any dollar amount — each is false the day that model ships.
    ///
    /// What it does claim, and why it stays true: the pro fee is flat and the client
    /// fee is a share of the DEPOSIT, so neither is ever a cut of the service price;
    /// and both fire only once per client↔pro pair on a cold discovery match, which
    /// is the rule today (isNewDiscoveryClient) and the rule in the planned model.
    /// The 20–30% figure is hedged and unattributed — a market observation from the
    /// brief's competitor scan, which applies to a NEW client's first appointment.
    public static func commissionPitchBody(brandName: String) -> String {
        "Many booking marketplaces take 20–30% of a new client's first appointment "
            + "out of the pro's payout — every time. \(brandName) never takes a "
            + "percentage of your service price. The only platform fee is small and "
            + "one-time, and it applies solely to the first booking from a brand-new "
            + "client who found you through Discovery or the Looks feed — never on a "
            + "returning client, a rebook, or anyone who came from your own link."
    }

    /// Studio is shown as an enterprise tier: no price, no purchase, contact only.
    /// Copy names nothing unbuilt — white-label in particular has no implementation.
    public static let studioTitle = "Salons & teams"
    public static let studioBody =
        "Studio is our plan for salons and teams — custom setup, billed by "
        + "arrangement. Get in touch and we'll walk you through it."
}
