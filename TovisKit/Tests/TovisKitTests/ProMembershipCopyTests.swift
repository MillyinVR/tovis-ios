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

    // 🔴 The pitch must stay true when the planned fee model ships: a pro-side $5
    // flat fee, and the client fee moving from flat $5 to 10% of the DEPOSIT. Any
    // of these phrases would become a lie that day, so none may appear.
    @Test func commissionPitchSurvivesThePlannedFeeModel() {
        let body = ProMembershipCopy.commissionPitchBody(brandName: "Tovis")
        #expect(!body.contains("$"))
        #expect(!body.lowercased().contains("keep 100%"))
        #expect(!body.lowercased().contains("0% of your deposits"))
        #expect(!body.lowercased().contains("paid by the client"))
        #expect(!body.lowercased().contains("flat fee"))
    }

    // What it DOES claim — the durable structural contrast, which holds because the
    // pro fee is flat and the client fee is a share of the DEPOSIT, so neither is
    // ever a cut of the service price.
    @Test func commissionPitchKeepsTheDurableClaims() {
        let body = ProMembershipCopy.commissionPitchBody(brandName: "Tovis")
        #expect(body.contains("20–30%"))
        #expect(body.contains("never takes a percentage of your service price"))
        #expect(body.contains("Tovis"))
        // The once-per-cold-match rule is true today and in the planned model.
        #expect(body.lowercased().contains("returning client"))
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
