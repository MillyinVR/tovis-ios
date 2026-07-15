import Foundation
import Testing
import TovisKit
@testable import Tovis

// ShotGuide is the "directed shoot" — pure data + selection logic: resolve a
// guide from a service name, filter trending packs by service, and build a guide
// from a server pack (mapping wire expectations, dropping unknown pose kinds).
@Suite struct ShotGuideTests {
    @Test func resolveMatchesProfessionKeywords() {
        #expect(ShotGuide.resolve(forServiceNamed: "Gel manicure") == .nails)
        #expect(ShotGuide.resolve(forServiceNamed: "Balayage") == .hair)
        #expect(ShotGuide.resolve(forServiceNamed: "Brow lamination") == .lashesBrows)
        #expect(ShotGuide.resolve(forServiceNamed: "Glam makeup") == .face)
        #expect(ShotGuide.resolve(forServiceNamed: "Deep tissue massage") == .generic)
        #expect(ShotGuide.resolve(forServiceNamed: nil) == .generic)
    }

    @Test func resolveTreatsWaxByBodyPartNotBareWax() {
        // "wax" alone is deliberately NOT a keyword (a leg wax is generic)…
        #expect(ShotGuide.resolve(forServiceNamed: "Leg wax") == .generic)
        // …but a brow wax still routes to the eye set via "brow".
        #expect(ShotGuide.resolve(forServiceNamed: "Brow wax") == .lashesBrows)
    }

    private let packsJSON = """
    {"version":1,"packs":[
      {"id":"hair-reveal-v1","name":"The Reveal","tagline":"t","serviceKeywords":["hair","balayage"],"trendScore":100,"steps":[
        {"title":"Back canvas","hint":"h","icon":"i","face":"absent","fillBandMin":0.25,"fillBandMax":0.9,"isDetail":false,"allowsClosedEyes":false,"pose":[
          {"kind":"shouldersLevel","params":{"maxDegrees":6},"tip":"t"},
          {"kind":"someFutureRuleKind","params":{"x":1},"tip":"t"}
        ]},
        {"title":"Detail","hint":"h","icon":"i","face":"either","fillBandMin":null,"fillBandMax":null,"isDetail":true,"allowsClosedEyes":false,"pose":[]}
      ]},
      {"id":"nails-claw-sparkle-v1","name":"Claw & Sparkle","tagline":"t","serviceKeywords":["nail","gel"],"trendScore":85,"steps":[
        {"title":"Macro","hint":"h","icon":"i","face":"required","fillBandMin":0.5,"fillBandMax":0.4,"isDetail":false,"allowsClosedEyes":false,"pose":[]}
      ]}
    ]}
    """

    private func decodePacks() throws -> [ProShotPack] {
        try JSONDecoder().decode(ProShotPacksResponse.self, from: Data(packsJSON.utf8)).packs
    }

    @Test func matchingPacksFiltersByServiceKeywords() throws {
        let packs = try decodePacks()
        #expect(ShotGuide.matchingPacks(packs, serviceName: "Balayage").map(\.id) == ["hair-reveal-v1"])
        #expect(ShotGuide.matchingPacks(packs, serviceName: "Gel set").map(\.id) == ["nails-claw-sparkle-v1"])
        #expect(ShotGuide.matchingPacks(packs, serviceName: "").isEmpty)
        #expect(ShotGuide.matchingPacks(packs, serviceName: nil).isEmpty)
    }

    @Test func initFromPackMapsExpectationsAndDropsUnknownPoseKinds() throws {
        let packs = try decodePacks()
        let guide = ShotGuide(pack: packs[0])
        #expect(guide.name == "The Reveal")
        #expect(guide.steps.count == 2)

        let back = guide.steps[0]
        #expect(back.expects.face == .absent)
        #expect(back.expects.fillBand == 0.25...0.9)
        // The unknown "someFutureRuleKind" is dropped; only the known rule stays.
        #expect(back.expects.poseRules.count == 1)
        #expect(back.expects.poseRules.first?.kind == .shouldersLevel)

        let detail = guide.steps[1]
        #expect(detail.expects.face == .either)
        #expect(detail.expects.isDetail)
        #expect(detail.expects.fillBand == nil)   // both bands null → no fill judgment

        // In the nails pack, fillBandMin >= fillBandMax → the band is discarded.
        let nails = ShotGuide(pack: packs[1])
        #expect(nails.steps[0].expects.face == .required)
        #expect(nails.steps[0].expects.fillBand == nil)
    }
}
