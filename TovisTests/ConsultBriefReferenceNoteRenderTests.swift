// C2-6b — the reference note on the pro Brief, rendered on the iOS toolchain
// over the contract fixture and written to a PNG a person can look at.
//
// Same shape as `ConsultBriefTopLineRenderTests`: the SHIPPING view over the
// SHIPPING wire shape, in both modes, at a phone width. It does not claim the
// Brief was reached by tapping through the app.
import Foundation
import SwiftUI
import Testing
import TovisKit
import UIKit
@testable import Tovis

@Suite @MainActor struct ConsultBriefReferenceNoteRenderTests {
    @Test func rendersTheServedNoteWholeInBothModes() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("TovisKit/Tests/TovisKitTests/Fixtures/consultSuitability.json")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let envelope = try #require(root["proBrief"] as? [String: Any])
        let payload = try #require(envelope["brief"] as? [String: Any])
        let brief = try JSONDecoder().decode(ProConsultBrief.self, from: JSONSerialization.data(withJSONObject: payload))
        let note = try #require(brief.inspirationCredibility)
        #expect(note.hasPrefix("Reference note: "))

        // A short note, for scale: the served note lists two flags and must
        // wrap to more than one line at a phone width, or the text was
        // clipped rather than wrapped.
        let oneLine = render(ProConsultReferenceNote(text: "Reference note: one angle only."), scheme: .light)
        for (scheme, name) in [(ColorScheme.light, "light"), (ColorScheme.dark, "dark")] {
            let image = render(ProConsultReferenceNote(text: note), scheme: scheme)
            #expect(image.size.width == 390)
            #expect(image.size.height > oneLine.size.height + 10)
            let png = try #require(image.pngData())
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("consult-brief-reference-note-\(name).png")
            try png.write(to: out)
            print("BRIEF REFERENCE NOTE SNAPSHOT → \(out.path)")
        }
    }

    private func render(_ view: ProConsultReferenceNote, scheme: ColorScheme) -> UIImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: 358).padding(16)
                .background(BrandColor.bgPrimary)
                .environment(\.colorScheme, scheme),
        )
        renderer.scale = 2
        // The top-line render test asserts the same width; a nil image here is
        // a broken view, and the force is what makes the test say so.
        return renderer.uiImage!
    }
}
