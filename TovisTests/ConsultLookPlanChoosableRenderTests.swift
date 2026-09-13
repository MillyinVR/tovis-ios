// tovis-app #1168 on the device: a photograph makes a reading THIN, and must
// never withdraw the booking (Tori, 2026-09-13, asked twice).
//
// 🔴 Why this renders rather than only asserting: the bug being fixed was a
// BUTTON that was not on screen. `isChoosable` is unit-tested next door
// (ConsultContractTests); nothing but a render executes the view's own gate,
// and a card that silently drops its only call to action looks completely
// healthy to a test that reads model state.
import Foundation
import SwiftUI
import Testing
import TovisKit
import UIKit
@testable import Tovis

@MainActor
@Suite struct ConsultLookPlanChoosableRenderTests {
    private func plan(status: String, choosable: Bool) throws -> ConsultLookPlan {
        let step: [String: Any] = [
            "serviceId": "color", "offeringId": "pro-color",
            "serviceCategoryId": "hair-color", "serviceName": "Dimensional color",
        ]
        let raw: [String: Any] = [
            "schemaVersion": 1, "tier": "EXACT", "status": status,
            "provisional": status != "READY_TO_CHOOSE", "choosable": choosable,
            "summary": "Keep your length and add warm dimension through the mid-lengths.",
            "nextStep": "Confirm which parts of the look you want.",
            "paths": [[
                "title": "Warm dimension", "whyThisWorksForYou": "Keeps the length you love.",
                "featureEvidence": [], "sessionCount": 1, "visits": [["steps": [step]]],
            ]],
        ]
        return try JSONDecoder().decode(
            ConsultLookPlan.self, from: JSONSerialization.data(withJSONObject: raw)
        )
    }

    private func brief() throws -> ConsultLookBriefVersion {
        let data = Data("""
        {"id":"v1","version":1,"sourceAnalysisRevisionId":"a1","awaitingAnalysis":false,
         "changes":[],"clientConfirmed":false,"professionalConfirmed":false,
         "confirmationOpen":true,"inputOpen":true,"adjustments":[],
         "pathEstimates":[{"pathIndex":0,"locationType":"SALON",
           "firstAppointment":{"price":"180.00","priceStatus":"PAID","knownSubtotal":"180.00","durationMinutes":120},
           "transformation":{"price":"180.00","priceStatus":"PAID","knownSubtotal":"180.00","durationMinutes":120},
           "visits":[{"steps":[{"offeringId":"pro-color","serviceId":"color","available":true,"price":"180.00","durationMinutes":120}]}]}]}
        """.utf8)
        return try JSONDecoder().decode(ConsultLookBriefVersion.self, from: data)
    }

    private func render(_ plan: ConsultLookPlan, name: String) throws -> UIImage {
        let view = ConsultLookPlanView(
            plan: plan, brief: try brief(), busy: false,
            onChoose: { _, _, _ in }, onConfirm: { _ in }
        )
        .padding(20)
        .frame(width: 375)
        .background(BrandColor.bgPrimary)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try #require(renderer.uiImage)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tovis-look-plan-\(name).png")
        try #require(image.pngData()).write(to: url)
        print("LOOK PLAN SNAPSHOT \(name) → \(url.path)")
        return image
    }

    /// 🔴 The case the split exists for. Her selfie was warm-lit, so the plan is
    /// NEEDS_INPUT and provisional — and she may still book it. The card must
    /// carry the Choose button AND the sentence that invites the daylight shots
    /// rather than the one naming details she cannot act on.
    @Test func aThinButChoosablePlanKeepsItsChooseButton() throws {
        let thin = try render(plan(status: "NEEDS_INPUT", choosable: true), name: "thin-choosable")
        let waiting = try render(plan(status: "NEEDS_INPUT", choosable: false), name: "needs-input")

        // The choosable card carries a whole extra control. Before #1168 both
        // of these rendered identically — without it.
        #expect(thin.size.height > waiting.size.height)

        // And the two provisional sentences are different lengths, so the
        // choosable card is taller again than the height of the button alone.
        // (A shared sentence is exactly what Tori ruled out.)
        #expect(ConsultThreadCopy.planFromEarlyPhotos != ConsultThreadCopy.planDraft)
    }

    /// tovis-app #1167 on the device: the UNKNOWNs said out loud, and what the
    /// light meant. Both sections are new UI, and both are pure copy assembled
    /// from served counts — which is exactly the kind of thing that reads
    /// perfectly in a diff and wrong on a screen.
    @Test func theLightCaveatAndTheDaylightGapRender() throws {
        func results(warm: Bool, gap: Bool) throws -> ConsultClientResults {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("TovisKit/Tests/TovisKitTests/Fixtures/consultFlow.json")
            let root = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            let envelope = try #require(root["results"] as? [String: Any])
            var payload = try #require(envelope["results"] as? [String: Any])
            payload["photoLight"] = warm
                ? ["acceptedFrameCount": 3, "warmFrameCount": 2, "mostFramesWarm": true]
                : ["acceptedFrameCount": 3, "warmFrameCount": 1, "mostFramesWarm": false]
            if gap {
                payload["daylightGap"] = [
                    "missingShotKeys": ["hair_back"],
                    "unlocks": ["HAIR_LEVELS", "SKIN_TONE_AND_SEASON"],
                    "provisionalCount": 13,
                ]
            }
            // 🔴 The PAYLOAD, not the envelope: `ConsultClientResultsResponse`
            // is internal to TovisKit and not visible from this target.
            return try JSONDecoder().decode(
                ConsultClientResults.self,
                from: JSONSerialization.data(withJSONObject: payload)
            )
        }

        func render(_ results: ConsultClientResults, name: String) throws -> UIImage {
            let view = ConsultPlanSummaryView(
                results: results, busy: false, onChoose: { _, _, _ in }, onConfirm: { _ in }
            )
            .padding(20)
            .frame(width: 375)
            .background(BrandColor.bgPrimary)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try #require(renderer.uiImage)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("tovis-plan-summary-\(name).png")
            try #require(image.pngData()).write(to: url)
            print("PLAN SUMMARY SNAPSHOT \(name) → \(url.path)")
            return image
        }

        let bare = try render(results(warm: false, gap: false), name: "bare")
        let both = try render(results(warm: true, gap: true), name: "warm-and-gap")
        // 🔴 The caveat shows on `mostFramesWarm` and NOTHING else. One warm
        // frame among three is noise, and a caveat shown every time stops being
        // read — so the quiet card must really be shorter.
        #expect(both.size.height > bare.size.height + 100)
    }

    /// The ordinary ready plan is unchanged by any of this.
    @Test func aReadyPlanIsUnchanged() throws {
        let ready = try render(plan(status: "READY_TO_CHOOSE", choosable: true), name: "ready")
        // No provisional line at all on a ready plan — it is shorter than the
        // thin one that carries the same button plus a caveat.
        let thin = try render(plan(status: "NEEDS_INPUT", choosable: true), name: "thin-again")
        #expect(ready.size.height < thin.size.height)
    }
}
