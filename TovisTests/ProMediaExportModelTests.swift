import Foundation
import Testing
import TovisKit
@testable import Tovis

// The client-export identity path (MediaExportIdentity.client) — a client
// exporting a DIFFERENT pro's work, added alongside the pro's own
// loadIdentity(_:). These drive ProMediaExportModel through the DEBUG-only
// seam (applyDebugClientExportTarget) rather than a network mock, mirroring
// how applyDebugIdentity already seeds the .own path for screenshots — see
// that method's own doc for why a seeded seam is preferred to faking state
// directly (it exercises the same computed properties a real load would).
@Suite @MainActor
struct ProMediaExportModelTests {
    private func targetContext() -> ProMediaExportContext {
        ProMediaExportContext(main: .bytes(Data()))
    }

    @Test func exportWatermarkUsesTheClientTargetNotTheOwnMembershipFields() {
        let model = ProMediaExportModel()
        model.applyDebugClientExportTarget(
            ClientExportTargetIdentity(
                handle: "dana", businessName: "Plume Studio",
                dropsPlatformMark: true, enabled: true
            )
        )

        let watermark = model.exportWatermark
        #expect(watermark.signature == "@dana")
        #expect(watermark.showsPlatformMark == false)
        // The .own fields were never touched by the client path.
        #expect(model.membership == nil)
        #expect(model.profile == nil)
    }

    @Test func exportWatermarkShowsThePlatformMarkWhenTheTargetProDoesNotDropIt() {
        let model = ProMediaExportModel()
        model.applyDebugClientExportTarget(
            ClientExportTargetIdentity(
                handle: "dana", businessName: nil,
                dropsPlatformMark: false, enabled: true
            )
        )

        #expect(model.exportWatermark.showsPlatformMark == true)
    }

    @Test func exportWatermarkFallsBackToBusinessNameWhenTheTargetProHasNoHandle() {
        let model = ProMediaExportModel()
        model.applyDebugClientExportTarget(
            ClientExportTargetIdentity(
                handle: nil, businessName: "Plume Studio",
                dropsPlatformMark: true, enabled: true
            )
        )

        #expect(model.exportWatermark.signature == "Plume Studio")
    }

    @Test func clientExportIsEnabledReflectsTheLoadedTarget() {
        let onModel = ProMediaExportModel()
        onModel.applyDebugClientExportTarget(
            ClientExportTargetIdentity(handle: "dana", businessName: nil, dropsPlatformMark: true, enabled: true)
        )
        #expect(onModel.clientExportIsEnabled == true)

        let offModel = ProMediaExportModel()
        offModel.applyDebugClientExportTarget(
            ClientExportTargetIdentity(handle: "dana", businessName: nil, dropsPlatformMark: true, enabled: false)
        )
        #expect(offModel.clientExportIsEnabled == false)
    }

    /// Generous default (matches SocialExportPolicy.dropsPlatformMark's own
    /// missing-signal default) BEFORE any identity has loaded — the bar reads
    /// this alongside `identityLoaded` precisely so it doesn't flash a button
    /// it then immediately hides for a pro who never even loaded.
    @Test func clientExportIsEnabledDefaultsTrueBeforeAnyLoad() {
        let model = ProMediaExportModel()
        #expect(model.identityLoaded == false)
        #expect(model.clientExportIsEnabled == true)
    }

    /// The routing itself: .own state (membership/profile) must never leak
    /// into a client export, and vice versa — the two identities are mutually
    /// exclusive inputs to the ONE signing function.
    @Test func theOwnPathIsUnaffectedWhenNoClientTargetIsSet() {
        let model = ProMediaExportModel()
        model.applyDebugIdentity(tier: "pro", handle: "tori")

        #expect(model.exportWatermark.signature == "@tori")
        #expect(model.exportWatermark.showsPlatformMark == false)
    }

    // Video can now export, for every identity — the PR #285 follow-up that
    // hardcoded `canExport` to `!isVideo` is gone. It still never pairs: there
    // is no diptych format for a clip, so `hasPair` stays false even when a
    // `before` happens to be set.
    @Test func canExportIsTrueForVideo() {
        let context = ProMediaExportContext(main: .bytes(Data()), isVideo: true)
        #expect(context.canExport == true)
    }

    @Test func hasPairStaysFalseForVideoEvenWithABeforeSet() {
        let context = ProMediaExportContext(
            main: .bytes(Data()), before: .bytes(Data()), isVideo: true
        )
        #expect(context.hasPair == false)
    }

    @Test func hasPairIsTrueForAPhotoWithABeforeSet() {
        let context = ProMediaExportContext(
            main: .bytes(Data()), before: .bytes(Data()), isVideo: false
        )
        #expect(context.hasPair == true)
    }
}
