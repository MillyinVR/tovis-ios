// C2-6a — the top line of the pro Brief, rendered on the iOS toolchain over
// the contract fixture and written to a PNG a person can look at.
//
// Same shape as `ProConsultFollowUpSectionRenderTests`: the SHIPPING view over
// the SHIPPING wire shape, in both modes, at a phone width. It does not claim
// the Brief was reached by tapping through the app.
import Foundation
import SwiftUI
import Testing
import TovisKit
import UIKit
@testable import Tovis

@Suite @MainActor struct ConsultBriefTopLineRenderTests {
    @Test func rendersTheServedSentenceWholeInBothModes() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("TovisKit/Tests/TovisKitTests/Fixtures/consultSuitability.json")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let envelope = try #require(root["proBrief"] as? [String: Any])
        let payload = try #require(envelope["brief"] as? [String: Any])
        let brief = try JSONDecoder().decode(ProConsultBrief.self, from: JSONSerialization.data(withJSONObject: payload))
        let line = try #require(brief.topLine)
        #expect(line.hasPrefix("Client wants "))

        // The one-line version, for scale: a sentence pair that wraps to
        // several lines must render taller than a single line at the same
        // width, or the text was clipped rather than wrapped.
        let oneLine = render(ProConsultTopLine(text: "Client wants the color."), scheme: .light)
        for (scheme, name) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
            let image = render(ProConsultTopLine(text: line), scheme: scheme)
            #expect(image.size.width == 390)
            #expect(image.size.height > oneLine.size.height + 20)
            let png = try #require(image.pngData())
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("consult-brief-top-line-\(name).png")
            try png.write(to: out)
            print("BRIEF TOP LINE SNAPSHOT → \(out.path)")
        }
    }

    private func render(_ view: ProConsultTopLine, scheme: ColorScheme) -> UIImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: 358).padding(16)
                .background(BrandColor.bgPrimary)
                .environment(\.colorScheme, scheme),
        )
        renderer.scale = 2
        // The follow-up render test asserts the same width; a nil image here
        // is a broken view, and the force is what makes the test say so.
        return renderer.uiImage!
    }
}
