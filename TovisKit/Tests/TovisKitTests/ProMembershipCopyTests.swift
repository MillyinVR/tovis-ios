import Foundation
import Testing
@testable import TovisKit

// Membership copy is a factual claim made to a paying pro, so it is tested like
// logic rather than trusted like a string literal. Context: tovis-app
// docs/design/membership-value-brief.md — the screen advertised
// `advanced_analytics`, which had zero implementation call sites in either repo.
@Suite struct ProMembershipCopyTests {
    @Test func freeTierPreviewNeverPromisesAnUnbuiltFeature() {
        let preview = ProMembershipCopy.proPreviewEntitlements
        // white_label has no implementation in either repo and is salon-only with
        // a minimum-pro-count purchase gate, so it is never previewed to a pro.
        #expect(!preview.contains("white_label"))
        // discovery_fee_waiver as CODED waives the CLIENT's fee; the intended perk
        // waives a pro-side fee that does not exist yet, so it is not previewed.
        #expect(!preview.contains("discovery_fee_waiver"))
        // advanced_analytics IS previewed — but only because it is now built
        // (the gated retention section on the web dashboard).
        #expect(preview.contains("advanced_analytics"))
        #expect(preview.contains("tax_export"))
        #expect(preview.contains("custom_handle"))
    }

    // 🔴 The load-bearing one. The old label function title-cased any unknown key,
    // so ANYTHING the server sent was advertised automatically. A comped Studio
    // partner was shown "White Label" for a feature with no implementation.
    @Test func anUnadvertisedEntitlementIsDroppedNotAutoTitled() {
        #expect(ProMembershipCopy.entitlementLabel("white_label") == nil)
        #expect(ProMembershipCopy.entitlementLabel("discovery_fee_waiver") == nil)
        #expect(ProMembershipCopy.entitlementLabel("some_future_key") == nil)

        let advertised = ProMembershipCopy.advertised([
            "custom_handle", "white_label", "tax_export", "discovery_fee_waiver",
            "some_future_key",
        ])
        #expect(advertised.map(\.key) == ["custom_handle", "tax_export"])
        #expect(advertised.allSatisfy { !$0.label.isEmpty })
    }

    @Test func everyPreviewedEntitlementHasCopy() {
        let advertised = ProMembershipCopy.advertised(
            ProMembershipCopy.proPreviewEntitlements,
        )
        #expect(advertised.count == ProMembershipCopy.proPreviewEntitlements.count)
    }

    // Tori chose this wording verbatim on 2026-08-04. Pinned exactly so a future
    // tidy cannot quietly reword a commercial claim, and so the string stays
    // byte-identical to web's feePitchBody (same apostrophe, same dash).
    @Test func feePitchIsTheApprovedCopyVerbatim() {
        #expect(
            ProMembershipCopy.commissionPitchBody(brandName: "Tovis")
                == "We never take a percentage of your work. Ever. "
                + "One flat $5 when Tovis brings you a brand-new client "
                + "— and members don\u{2019}t even pay that."
        )
    }

    // 🔴 Durability under the planned fee model (brief §11.5): the pro fee is a
    // FLAT $5, so "never a percentage of your work" holds; the client fee becomes a
    // share of the DEPOSIT, which is still not a percentage of the pro's work.
    @Test func feePitchNeverClaimsAPercentageIsTakenFromThePro() {
        let body = ProMembershipCopy.commissionPitchBody(brandName: "Tovis").lowercased()
        #expect(body.contains("never take a percentage of your work"))
        // "keep 100%" would be false the day the pro-side $5 ships.
        #expect(!body.contains("keep 100%"))
        #expect(!body.contains("% of your service"))
    }

    @Test func feePitchUsesTheBrandNameItIsGiven() {
        let body = ProMembershipCopy.commissionPitchBody(brandName: "Salon X")
        #expect(body.contains("when Salon X brings you"))
        #expect(!body.contains("Tovis"))
    }

    // Studio is shown but never sold, so its copy must not name an unbuilt feature.
    @Test func studioCopyNamesNothingUnbuilt() {
        let copy = (ProMembershipCopy.studioTitle + " " + ProMembershipCopy.studioBody)
            .lowercased()
        #expect(!copy.contains("white label"))
        #expect(!copy.contains("white-label"))
        #expect(!copy.contains("$"))
    }
}
