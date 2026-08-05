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
        "discovery_fee_waiver",
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
        case "discovery_fee_waiver": return "No platform fee for your new discovery clients"
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

    public static let commissionPitchTitle = "You keep 100% of what you charge"

    /// The commission pitch body — the strongest true thing about the platform, and
    /// it was nowhere in the membership story (membership-value-brief.md §0.4 / §3.1).
    ///
    /// Every claim is checkable in tovis-app: the only `application_fee_amount` the
    /// platform ever charges is the discovery fee, deposits settle to the pro in
    /// full, and the fee is charged solely to a brand-new client arriving via
    /// LOOKS_FEED / DISCOVERY_SEARCH (`isNewDiscoveryClient`). The 20–30% figure is
    /// hedged and unattributed — a market observation from the brief's competitor
    /// scan, not a per-competitor claim we can verify at render time.
    ///
    /// `feeCents` comes from the server so the amount tracks the configured fee
    /// (env-overridable up to $10). When it is nil — an older server, or a build
    /// running before that field deploys — we keep the 0%-commission claim and drop
    /// the sentence that would need a number. Never hardcode $5 here.
    public static func commissionPitchBody(feeCents: Int?, brandName: String) -> String {
        let lead = "Many booking marketplaces take 20–30% of a new client's first "
            + "appointment out of the pro's payout. \(brandName) takes 0% of your "
            + "services and 0% of your deposits, on every plan."
        guard let fee = Wire.moneyCents(feeCents) else { return lead }
        return lead + " The one platform fee is a flat \(fee) paid by the client, "
            + "once, the first time a brand-new client books you from Discovery or "
            + "the Looks feed."
    }
}
