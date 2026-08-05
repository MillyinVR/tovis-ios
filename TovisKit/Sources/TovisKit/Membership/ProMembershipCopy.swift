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

    /// The fee pitch, exactly as Tori chose it on 2026-08-04 (option A, verbatim).
    /// Mirrors `feePitchBody` in tovis-app app/pro/membership/entitlementCopy.ts.
    ///
    /// 🔴 THIS COPY DESCRIBES THE PLANNED FEE MODEL, NOT TODAY'S CODE. Under that
    /// model (brief §11.5) the pro pays a flat $5 once per cold-match client and
    /// membership waives it — which is what this says, and it stays true when the
    /// model ships.
    ///
    /// Today there is NO pro-side fee: the $5 is charged to the CLIENT, and
    /// `discovery_fee_waiver` is flag-gated off. So a pro reading this today is
    /// told they pay something they do not, and that membership waives something it
    /// does not yet waive. Tori chose this wording knowingly; the safe sequencing is
    /// to ship it WITH the fee-model card, not before it.
    public static func commissionPitchBody(brandName: String) -> String {
        "We never take a percentage of your work. Ever. "
            + "One flat $5 when \(brandName) brings you a brand-new client "
            + "— and members don’t even pay that."
    }

    /// Studio is shown as an enterprise tier: no price, no purchase, contact only.
    /// Copy names nothing unbuilt — white-label in particular has no implementation.
    public static let studioTitle = "Salons & teams"
    public static let studioBody =
        "Studio is our plan for salons and teams — custom setup, billed by "
        + "arrangement. Get in touch and we'll walk you through it."
}
