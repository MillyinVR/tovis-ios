import Foundation
import Testing
@testable import TovisKit

struct ConsultSuitabilityTests {
    private func payload(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: "consultSuitability", withExtension: "json"))
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let envelope = try #require(root[name] as? [String: Any])
        return try #require(envelope[name == "results" ? "results" : "brief"] as? [String: Any])
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }

    @Test func bothRoleFixturesDecodeAndPreserveEvidence() throws {
        let client = try decode(ConsultClientResults.self, payload("results"))
        #expect(client.currentSuitability?.whatYouLoved == ["Soft copper ribbons"])
        #expect(client.currentSuitability?.tailoring.first?.needsConfirmation == true)
        let pro = try decode(ProConsultBrief.self, payload("proBrief"))
        let sources = try #require(pro.currentSuitability?.tailoring.first?.sources)
        #expect(sources.map(\.provenance) == ["CLIENT_REPORTED", "OBSERVED"])
        #expect(sources[0].confidence == nil)
        #expect(sources[1].confidence?.min == 0.6)
        #expect(sources[1].evidence == ["Daylight front view"])
        #expect(pro.currentSuitability?.proConfirmations.first?.sources.first?.label == "Starting color")
    }

    @Test func historicalMissingAndNullSuitabilityStillDecode() throws {
        for null in [false, true] {
            var client = try payload("results")
            var pro = try payload("proBrief")
            client.removeValue(forKey: "suitability")
            pro.removeValue(forKey: "suitability")
            pro.removeValue(forKey: "sourceAnalysisRevisionId")
            if null { client["suitability"] = NSNull(); pro["suitability"] = NSNull() }
            #expect(try decode(ConsultClientResults.self, client).currentSuitability == nil)
            #expect(try decode(ProConsultBrief.self, pro).currentSuitability == nil)
        }
    }

    @Test func mismatchedAndMissingParentRevisionNeverRender() throws {
        var client = try payload("results")
        client["analysisRevisionId"] = "new-analysis"
        #expect(try decode(ConsultClientResults.self, client).currentSuitability == nil)
        var pro = try payload("proBrief")
        pro["sourceAnalysisRevisionId"] = "new-analysis"
        #expect(try decode(ProConsultBrief.self, pro).currentSuitability == nil)
        pro.removeValue(forKey: "sourceAnalysisRevisionId")
        #expect(try decode(ProConsultBrief.self, pro).currentSuitability == nil)
    }

    @Test func emptySectionsDecodeWithoutInventingAdvice() throws {
        var client = try payload("results")
        var suitability = try #require(client["suitability"] as? [String: Any])
        for key in ["whatYouLoved", "tailoring", "proConfirmations"] { suitability[key] = [] as [String] }
        client["suitability"] = suitability
        #expect(try decode(ConsultClientResults.self, client).currentSuitability?.tailoring.isEmpty == true)
    }

    @Test func activeRenderingUsesRevisionGuardsAndSeparateRoleViews() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let client = try String(contentsOf: repo.appendingPathComponent("Tovis/ConsultThreadView.swift"), encoding: .utf8)
        let pro = try String(contentsOf: repo.appendingPathComponent("Tovis/ProConsultQueueView.swift"), encoding: .utf8)
        let views = try String(contentsOf: repo.appendingPathComponent("Tovis/ConsultSuitabilityView.swift"), encoding: .utf8)
        #expect(client.contains("if let suitability = results.currentSuitability"))
        #expect(client.contains("ClientSuitabilityView(suitability: suitability)"))
        #expect(pro.contains("if let suitability = brief.currentSuitability"))
        #expect(pro.contains("ProSuitabilityView(suitability: suitability)"))
        let clientOnly = try #require(views.components(separatedBy: "struct ProSuitabilityView").first)
        #expect(!clientOnly.contains("source.provenance"))
        #expect(!clientOnly.contains("item.direction"))
        #expect(views.contains("source.label"))
        #expect(views.contains("source.value"))
        #expect(views.contains("ConsultSuitabilityCopy.observationUncertainty"))
        #expect(ConsultSuitabilityCopy.provenance("CLIENT_REPORTED") == "Client-reported")
        #expect(ConsultSuitabilityCopy.provenance("OBSERVED") == "Observed")
    }
}
