import Foundation
import SwiftUI
import Testing
import TovisKit
import UIKit
@testable import Tovis

/// Renders shipping role views from synthetic wire fixtures; no account or API.
@MainActor
@Suite struct ConsultSuitabilityRenderTests {
    private func payload(_ name: String) throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("TovisKit/Tests/TovisKitTests/Fixtures/consultSuitability.json")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let envelope = try #require(root[name] as? [String: Any])
        return try #require(envelope[name == "results" ? "results" : "brief"] as? [String: Any])
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
    private func render<V: View>(_ view: V, name: String, size: DynamicTypeSize = .large) throws -> UIImage {
        let renderer = ImageRenderer(content: view
            .padding(20).frame(width: 375)
            .background(BrandColor.bgPrimary)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, size))
        renderer.scale = 2
        let image = try #require(renderer.uiImage)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tovis-suitability-\(name).png")
        try #require(image.pngData()).write(to: url)
        print("SUITABILITY SNAPSHOT → \(url.path)")
        return image
    }
    @Test func rendersBothRoleViewsAtNarrowWidthAndLargeText() throws {
        let client = try #require(decode(ConsultClientResults.self, payload("results")).currentSuitability)
        let pro = try #require(decode(ProConsultBrief.self, payload("proBrief")).currentSuitability)
        for (name, size) in [("standard", DynamicTypeSize.large), ("large-text", .accessibility3)] {
            let clientImage = try render(ClientSuitabilityView(suitability: client), name: "client-\(name)", size: size)
            let proImage = try render(ProSuitabilityView(suitability: pro), name: "pro-\(name)", size: size)
            #expect(clientImage.size.height > 150)
            #expect(proImage.size.height > clientImage.size.height)
        }
    }
    @Test func absentAndStaleGuidanceRenderOnlyTheExistingContent() throws {
        let baseline = try render(Text("Existing consultation content"), name: "baseline")
        for state in ["missing", "stale"] {
            var clientPayload = try payload("results")
            var proPayload = try payload("proBrief")
            if state == "missing" {
                clientPayload.removeValue(forKey: "suitability")
                proPayload.removeValue(forKey: "suitability")
                proPayload.removeValue(forKey: "sourceAnalysisRevisionId")
            } else {
                clientPayload["analysisRevisionId"] = "new-analysis"
                proPayload["sourceAnalysisRevisionId"] = "new-analysis"
            }
            let client = try decode(ConsultClientResults.self, clientPayload)
            let pro = try decode(ProConsultBrief.self, proPayload)
            // The exact guards used by the active thread and pro brief views.
            let clientImage = try render(VStack {
                Text("Existing consultation content")
                if let suitability = client.currentSuitability { ClientSuitabilityView(suitability: suitability) }
            }, name: "client-\(state)")
            let proImage = try render(VStack {
                Text("Existing consultation content")
                if let suitability = pro.currentSuitability { ProSuitabilityView(suitability: suitability) }
            }, name: "pro-\(state)")
            #expect(clientImage.pngData() == baseline.pngData())
            #expect(proImage.pngData() == baseline.pngData())
        }
    }
}
