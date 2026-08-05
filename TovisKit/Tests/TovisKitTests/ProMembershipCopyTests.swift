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
        #expect(ProMembershipCopy.entitlementLabel("some_future_key") == nil)

        let advertised = ProMembershipCopy.advertised([
            "custom_handle", "white_label", "tax_export", "some_future_key",
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

    @Test func commissionPitchStatesTheServersFeeNotAHardcodedFive() {
        let body = ProMembershipCopy.commissionPitchBody(feeCents: 500, brandName: "Tovis")
        #expect(body.contains("$5"))
        #expect(body.contains("0% of your services"))
        #expect(body.contains("Tovis"))

        // The fee is env-overridable up to $10 server-side; the copy must follow it.
        let raised = ProMembershipCopy.commissionPitchBody(feeCents: 1000, brandName: "Tovis")
        #expect(raised.contains("$10"))
        #expect(!raised.contains("$5 "))
    }

    // An older server (or a build shipped before the field deploys) sends no fee.
    // The 0%-commission claim is still true and must survive; the sentence that
    // needs a number must not render with a placeholder or a stale $5.
    @Test func commissionPitchDropsTheAmountWhenTheServerDoesNotSendOne() {
        let body = ProMembershipCopy.commissionPitchBody(feeCents: nil, brandName: "Tovis")
        #expect(body.contains("0% of your services"))
        #expect(!body.contains("$"))
        #expect(!body.contains("flat"))
    }
}
