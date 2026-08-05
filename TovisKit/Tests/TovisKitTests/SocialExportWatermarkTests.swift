import Foundation
import Testing
@testable import TovisKit

// 🔴 The three claims the export pack makes, each of which is invisible from the
// outside and expensive to get wrong:
//
//   1. a SAVE is never marked — on any tier, in any membership state, ever;
//   2. an EXPORT always carries the pro's own signature;
//   3. the platform mark is present for a free pro and absent for a member —
//      BOTH directions, because each failure is its own kind of broken promise.

/// Membership is decode-only (it mirrors a server payload), so build it the way
/// the app does — which also keeps the field name honest against the wire.
private func membership(exportsUnbranded: Bool?, plan: String = "pro") -> ProMembership {
    var fields = """
    "planKey":"\(plan)","rawPlanKey":"\(plan)","status":"active",
    "compPlanKey":null,"compUntil":null,"entitlements":[],
    "currentPeriodEnd":null,"cancelAtPeriodEnd":false,
    "trialEndsAt":null,"hasBillingAccount":true
    """
    if let exportsUnbranded {
        fields += ",\"exportsUnbranded\":\(exportsUnbranded)"
    }
    let json = Data("{\"membership\":{\(fields)}}".utf8)
    // swiftlint:disable:next force_try
    return try! JSONDecoder().decode(ProMembershipResponse.self, from: json).membership
}

private let free = membership(exportsUnbranded: false, plan: "free")
private let member = membership(exportsUnbranded: true)
private let legacyBackend = membership(exportsUnbranded: nil)

private func watermark(
    _ intent: MediaWriteIntent,
    _ m: ProMembership?,
    handle: String? = "tori",
    businessName: String? = "Tori Studio"
) -> ExportWatermark? {
    SocialExportPolicy.watermark(
        for: intent, membership: m, handle: handle,
        businessName: businessName, platformMark: "Tovis"
    )
}

@Suite struct SocialExportSaveIsNeverMarkedTests {
    // 🔴 Rule 1, exhaustively. A save-to-Photos is the pro leaving with their own
    // photograph. No plan, no entitlement and no missing membership may put ink on
    // it — so this asserts across every state the other rules branch on, not just
    // the happy one.
    @Test func noMembershipStateCanMarkASave() {
        for m in [free, member, legacyBackend, nil] {
            #expect(watermark(.saveOriginal, m) == nil)
        }
    }

    @Test func aSaveIsCleanEvenForAProWithNoHandleAndNoName() {
        #expect(watermark(.saveOriginal, free, handle: nil, businessName: nil) == nil)
        #expect(watermark(.saveOriginal, member, handle: nil, businessName: nil) == nil)
    }
}

@Suite struct SocialExportPlatformMarkTests {
    // Direction A: a free pro's export carries the mark. Miss this and the mark
    // never ships anywhere, and the membership page is selling nothing.
    @Test func aFreeProSExportCarriesThePlatformMark() {
        let w = watermark(.socialExport, free)
        #expect(w?.showsPlatformMark == true)
        #expect(w?.platformMark == "Tovis")
        #expect(w?.isEmpty == false)
    }

    // Direction B: a member's does not. Miss this and every paying pro's exports
    // carry a mark they paid to remove.
    @Test func aMemberSExportDropsThePlatformMark() {
        let w = watermark(.socialExport, member)
        #expect(w?.showsPlatformMark == false)
    }

    // The two are genuinely different renders, not the same object described twice.
    @Test func theTwoTiersDoNotProduceTheSameWatermark() {
        #expect(watermark(.socialExport, free) != watermark(.socialExport, member))
    }

    // Missing answers fail GENEROUS — see `dropsPlatformMark`. A free pro's absent
    // mark costs a little reach; a member whose signal dropped seeing a mark
    // appear is a broken promise they can point at. It also matches production
    // today, where enforcement is off and the server answers "unbranded" anyway.
    @Test func aMissingAnswerFailsGenerous() {
        #expect(watermark(.socialExport, legacyBackend)?.showsPlatformMark == false)
        #expect(watermark(.socialExport, nil)?.showsPlatformMark == false)
        #expect(SocialExportPolicy.dropsPlatformMark(nil) == true)
        #expect(SocialExportPolicy.dropsPlatformMark(legacyBackend) == true)
        #expect(SocialExportPolicy.dropsPlatformMark(free) == false)
    }

    // The app must read the server's resolved boolean, not re-derive the tier from
    // the entitlement list — that is the whole reason the field exists.
    @Test func theResolvedBooleanWinsOverThePlanKey() {
        // A "premium" row the server has resolved as branded (lapsed, comped down,
        // enforcement rules we don't model here) must render branded.
        #expect(
            SocialExportPolicy.dropsPlatformMark(
                membership(exportsUnbranded: false, plan: "premium")
            ) == false
        )
        // ...and a "free" row the server resolved as unbranded (today's production
        // state, enforcement off) must render unbranded.
        #expect(
            SocialExportPolicy.dropsPlatformMark(
                membership(exportsUnbranded: true, plan: "free")
            ) == true
        )
    }

    @Test func theEntitlementKeyMatchesTheServerS() {
        #expect(SocialExportPolicy.unbrandedEntitlement == "social_export_unbranded")
    }
}

@Suite struct SocialExportSignatureTests {
    // The signature is never a paid feature — the work is theirs on every tier.
    @Test func everyTierSExportIsSignedWithTheProSOwnHandle() {
        for m in [free, member, legacyBackend, nil] {
            #expect(watermark(.socialExport, m)?.signature == "@tori")
        }
    }

    @Test func handlesNormaliseToASingleLeadingAt() {
        #expect(SocialExportPolicy.normalizedHandle("tori") == "@tori")
        #expect(SocialExportPolicy.normalizedHandle("@tori") == "@tori")
        #expect(SocialExportPolicy.normalizedHandle("  @tori  ") == "@tori")
        #expect(SocialExportPolicy.normalizedHandle("@@tori") == "@tori")
    }

    // A blank handle must fall through to the business name rather than signing
    // the print "@".
    @Test func anEmptyHandleIsNotASignature() {
        #expect(SocialExportPolicy.normalizedHandle("") == nil)
        #expect(SocialExportPolicy.normalizedHandle("   ") == nil)
        #expect(SocialExportPolicy.normalizedHandle("@") == nil)
        #expect(SocialExportPolicy.normalizedHandle(nil) == nil)
        #expect(watermark(.socialExport, free, handle: "@")?.signature == "Tori Studio")
    }

    @Test func theBusinessNameIsTheFallbackAndNothingIsInvented() {
        #expect(SocialExportPolicy.signature(handle: nil, businessName: "Tori Studio") == "Tori Studio")
        #expect(SocialExportPolicy.signature(handle: nil, businessName: "   ") == nil)
        #expect(SocialExportPolicy.signature(handle: nil, businessName: nil) == nil)
    }

    // A member with nothing to sign with gets an unmarked export — legitimate, it
    // is their photo. The sheet nudges them to set a handle rather than the code
    // inventing one.
    @Test func aMemberWithNoNameGetsACompletelyCleanExport() {
        let w = watermark(.socialExport, member, handle: nil, businessName: nil)
        #expect(w?.isEmpty == true)
    }

    // ...but a FREE pro with no name still carries the mark. "Nothing to sign
    // with" must not become a free upgrade.
    @Test func aFreeProWithNoNameStillCarriesTheMark() {
        let w = watermark(.socialExport, free, handle: nil, businessName: nil)
        #expect(w?.signature == nil)
        #expect(w?.showsPlatformMark == true)
        #expect(w?.isEmpty == false)
    }

    // White-label: the mark is whatever the tenant is called, never a literal.
    @Test func thePlatformMarkIsTheTenantSName() {
        let w = SocialExportPolicy.watermark(
            for: .socialExport, membership: free, handle: "tori",
            businessName: nil, platformMark: "SALON X"
        )
        #expect(w?.platformMark == "SALON X")
    }
}

@Suite struct ProMembershipExportFieldDecodeTests {
    // The field is optional on the wire so a backend older than it still decodes —
    // and an old backend is one with enforcement off, where "unbranded" is the
    // right answer anyway.
    @Test func aPayloadWithoutTheFieldStillDecodes() {
        #expect(legacyBackend.exportsUnbranded == nil)
        #expect(legacyBackend.planKey == "pro")
    }

    @Test func thePayloadWithTheFieldDecodesBothWays() {
        #expect(membership(exportsUnbranded: true).exportsUnbranded == true)
        #expect(membership(exportsUnbranded: false).exportsUnbranded == false)
    }
}
