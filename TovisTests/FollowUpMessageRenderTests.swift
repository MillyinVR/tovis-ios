// P5g — the adaptive follow-up card and the region picker, rendered on the iOS
// toolchain and written to a PNG a person can look at.
//
// Same shape and same limits as `PlanUpdateMessageRenderTests`: this renders
// the SHIPPING views over the SHIPPING wire shape. It does not claim the card
// was reached by tapping through the app.
//
// 🔴 Why a render test and not only a decode test. The web side of P5g had two
// defects that every assertion passed and only a screenshot showed: a portrait
// reference rendered a card one and a half viewports tall, and the boxes over
// the photograph were too faint to read as controls. Neither is expressible as
// an expectation about a value. The PNG is the point.
import Foundation
import SwiftUI
import Testing
import TovisKit
import UIKit
@testable import Tovis

@MainActor
@Suite struct FollowUpMessageRenderTests {
    /// The wire shape of one generated follow-up, and one fallback.
    private func message(fallback: Bool) throws -> ConsultThreadMessage {
        let json = """
        {
          "kind": "FOLLOW_UP",
          "id": "follow-up:1:prior_lightening",
          "author": "APP",
          "state": "OPEN",
          "text": \(fallback
            ? "\"When was your hair last lightened?\""
            : "\"You’re at a light brown now and you loved the ash — that’s usually two visits. When was your hair last lightened?\""),
          "questionKey": "prior_lightening",
          "options": [
            { "value": "never", "label": "Never" },
            { "value": "within-3-months", "label": "In the last few months" },
            { "value": "over-12-months", "label": "Over a year ago" },
            { "value": "not-sure", "label": "I don’t remember" }
          ],
          "selectedValues": [],
          "fallback": \(fallback),
          "round": 1
        }
        """
        return try JSONDecoder().decode(
            ConsultThreadMessage.self, from: Data(json.utf8)
        )
    }

    @Test func decodesBothShapes() throws {
        let generated = try message(fallback: false)
        #expect(generated.kind == .followUp)
        #expect(generated.questionKey == "prior_lightening")
        #expect(generated.followUpOptions?.count == 4)
        #expect(generated.fallback == false)
        // 🔴 The fallback flag is what the card marks itself with. Part 0 rule 4
        // forbids a fallback the client cannot see.
        #expect(try message(fallback: true).fallback == true)
    }

    /// P5g — the region hotspots, laid out at a known size.
    ///
    /// 🔴 The offset arithmetic is the part of the picker that can be silently
    /// wrong: a box positioned against the CARD rather than against the image,
    /// or a fraction applied to the wrong axis, renders a plausible grid over
    /// the wrong parts of a photograph and no assertion about a value would
    /// notice. This lays three regions out over a known 300x450 box — the same
    /// three the blonde reference produces — and writes the PNG.
    @Test func rendersTheRegionHotspots() throws {
        let size = CGSize(width: 300, height: 450)
        // Decoded from the wire shape rather than constructed: TovisKit's
        // memberwise inits are internal to that module, and decoding proves the
        // same JSON the server sends produces these boxes.
        let options = try JSONDecoder().decode(
            [ConsultInspirationCardOption].self,
            from: Data("""
            [
              {"value":"base-level","label":"light brown",
               "region":{"x":0.35,"y":0.05,"w":0.3,"h":0.15}},
              {"value":"tone","label":"cool, silvery cast",
               "region":{"x":0.32,"y":0.42,"w":0.36,"h":0.16}},
              {"value":"lightest-level","label":"light blonde",
               "region":{"x":0.3,"y":0.6,"w":0.4,"h":0.3}}
            ]
            """.utf8)
        )
        let view = ZStack(alignment: .topLeading) {
            Rectangle().fill(BrandColor.bgSecondary)
            ForEach(options) { option in
                ConsultRegionHotspot(
                    option: option,
                    size: size,
                    // One selected, so both states are in the same picture.
                    active: option.value == "tone",
                    onTap: {}
                )
            }
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try #require(renderer.uiImage)
        let png = try #require(image.pngData())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tovis-region-hotspots.png")
        try png.write(to: url)
        print("REGION HOTSPOTS SNAPSHOT → \(url.path)")
        #expect(image.size.width == size.width)
        #expect(image.size.height == size.height)
    }

    @Test func rendersTheFollowUpCard() throws {
        for fallback in [false, true] {
            let view = FollowUpMessageView(
                message: try message(fallback: fallback),
                busy: false,
                onAnswer: { _ in }
            )
            .padding(20)
            .frame(width: 390)
            .background(BrandColor.bgPrimary)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try #require(renderer.uiImage)
            let png = try #require(image.pngData())
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "tovis-follow-up-\(fallback ? "fallback" : "generated").png"
                )
            try png.write(to: url)
            print("FOLLOW UP SNAPSHOT \(fallback ? "fallback" : "generated") → \(url.path)")
            // A card that rendered its question and swallowed its four options
            // would still produce an image; the HEIGHT is what says the options
            // are on screen.
            #expect(image.size.height > 160)
        }
    }
}

/// C2-4 — the SAME card, with the pro's name on it.
@Suite @MainActor struct ProFollowUpMessageRenderTests {
    private func proCard() throws -> ConsultThreadMessage {
        let json = """
        {
          "kind": "FOLLOW_UP",
          "id": "pro-follow-up:pro_1",
          "author": "APP",
          "state": "OPEN",
          "text": "Have you had keratin or a smoothing treatment in the last year?",
          "attribution": "From Susie",
          "questionKey": "pro_1",
          "options": [
            { "value": "option-1", "label": "Yes, within the year" },
            { "value": "option-2", "label": "No" },
            { "value": "option-3", "label": "Not sure" }
          ],
          "selectedValues": [],
          "fallback": false,
          "round": 0
        }
        """
        return try JSONDecoder().decode(ConsultThreadMessage.self, from: Data(json.utf8))
    }

    @Test func decodesTheAttribution() throws {
        let card = try proCard()
        #expect(card.attribution == "From Susie")
        #expect(card.round == 0)
        #expect(card.questionKey == "pro_1")
    }

    /// The eyebrow adds a line above the question; a card that swallowed it
    /// would be exactly as tall as the model's card with the same options.
    @Test func rendersTheEyebrowAboveTheQuestion() throws {
        func height(_ message: ConsultThreadMessage, _ name: String) throws -> CGFloat {
            let view = FollowUpMessageView(message: message, busy: false, onAnswer: { _ in })
                .padding(20).frame(width: 390).background(BrandColor.bgPrimary)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try #require(renderer.uiImage)
            let png = try #require(image.pngData())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tovis-follow-up-\(name).png")
            try png.write(to: url)
            print("FOLLOW UP SNAPSHOT \(name) → \(url.path)")
            return image.size.height
        }
        let attributed = try proCard()
        // The same card with the eyebrow removed, and nothing else changed.
        let plainJSON = """
        {
          "kind": "FOLLOW_UP", "id": "pro-follow-up:pro_1", "author": "APP", "state": "OPEN",
          "text": "Have you had keratin or a smoothing treatment in the last year?",
          "questionKey": "pro_1",
          "options": [
            { "value": "option-1", "label": "Yes, within the year" },
            { "value": "option-2", "label": "No" },
            { "value": "option-3", "label": "Not sure" }
          ],
          "selectedValues": [], "fallback": false, "round": 0
        }
        """
        let plain = try JSONDecoder().decode(ConsultThreadMessage.self, from: Data(plainJSON.utf8))
        #expect(plain.attribution == nil)
        let withEyebrow = try height(attributed, "pro-attributed")
        let without = try height(plain, "pro-plain")
        #expect(withEyebrow > without)
        #expect(without > 160)
    }
}

/// C2-4 — the pro's section on the Brief, in both modes, off the contract
/// fixture: one open question, one answered, and the button.
@Suite @MainActor struct ProConsultFollowUpSectionRenderTests {
    @Test func rendersAskedQuestionsAndTheControlInBothModes() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("TovisKit/Tests/TovisKitTests/Fixtures/consultSuitability.json")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let envelope = try #require(root["proBrief"] as? [String: Any])
        let payload = try #require(envelope["brief"] as? [String: Any])
        let brief = try JSONDecoder().decode(ProConsultBrief.self, from: JSONSerialization.data(withJSONObject: payload))
        let questions = try #require(brief.proFollowUps)
        #expect(questions.count == 2)
        for (scheme, name) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
            let view = ProConsultFollowUpSection(consultId: brief.consultId, questions: questions, busy: false, onAsked: {})
                .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
                .frame(width: 358).padding(16).background(BrandColor.bgPrimary).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.uiImage)
            #expect(image.size.width == 390)
            // Title, intro, two question rows and the button: a section that
            // dropped the rows would be far shorter.
            #expect(image.size.height > 260)
            let png = try #require(image.pngData())
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("consult-pro-follow-ups-\(name).png")
            try png.write(to: out)
            print("PRO FOLLOW-UPS SNAPSHOT → \(out.path)")
        }
    }
}

@Suite @MainActor struct ConsultMentorRenderTests {
    @Test func rendersDatabaseDerivedMentorInBothModes() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/consultMentor.json")
        let mentor = try JSONDecoder().decode(ConsultMentor.self, from: Data(contentsOf: fixture))
        #expect(mentor.sections.map(\.id) == [1, 2, 3, 4, 5])
        for (scheme, name) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
            let view = ConsultMentorLayer(mentor: mentor).frame(width: 358).padding(16)
                .background(BrandColor.bgPrimary).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.uiImage)
            #expect(image.size.width == 390)
            let png = try #require(image.pngData())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("consult-mentor-\(name).png")
            try png.write(to: url)
            print("MENTOR SNAPSHOT → \(url.path)")
        }
    }
}


@Suite @MainActor struct ConsultParityRenderTests {
    @Test func rendersProfessionalEvidenceSafetyAndEstimateInBothModes() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/consultParityBrief.json")
        let brief = try JSONDecoder().decode(ProConsultBrief.self, from: Data(contentsOf: fixture))
        #expect(brief.aiObservations != nil)
        #expect(brief.safetyFlags != nil)
        #expect(brief.serviceEstimate?.lines.first?.estimatedPrice == "180.50")
        for (scheme, name) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
            let view = VStack(alignment: .leading, spacing: 18) {
                ProConsultVersionSummary(brief: brief)
                ProConsultEvidence(brief: brief)
                ProConsultSafety(brief: brief)
                ProConsultEstimateAndDirections(brief: brief)
            }.font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
                .frame(width: 358).padding(16).background(BrandColor.bgPrimary).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.uiImage)
            #expect(image.size.width == 390)
            let png = try #require(image.pngData())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("consult-parity-pro-\(name).png")
            try png.write(to: url)
            print("PARITY SNAPSHOT → \(url.path)")
        }
    }
}
