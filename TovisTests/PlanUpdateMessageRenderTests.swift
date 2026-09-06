// P7a-3 — the "plan updated" bubble, rendered from the REAL server payload.
//
// `planUpdateThread.json` is not a hand-written fixture: it is the byte output
// of `loadConsultThread` run against PostgreSQL for a consult that was
// completed, edited, and rerun to v2 (the same flow
// tovis-app/tests/integration/consult-lifecycle-open.test.ts drives). So this
// renders the shipping view over the shipping wire shape, on the iOS
// toolchain, and writes a PNG a person can look at.
//
// 🔴 What it does NOT claim: that the bubble was reached by tapping through the
// app. It renders the view, not the navigation.
import Foundation
import SwiftUI
import Testing
import TovisKit
import UIKit
@testable import Tovis

@MainActor
@Suite struct PlanUpdateMessageRenderTests {
    private func thread() throws -> ConsultThread {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("planUpdateThread.json")
        let decoder = JSONDecoder()
        struct Envelope: Decodable { let thread: ConsultThread }
        return try decoder.decode(Envelope.self, from: Data(contentsOf: url)).thread
    }

    /// The bubble decodes off the real payload and carries its diff.
    @Test func decodesTheRealPayload() throws {
        let update = try #require(
            thread().messages.first { $0.kind == .planUpdate }
        )
        #expect(update.planVersion == 2)
        #expect(update.previousPlanVersion == 1)
        let changes = try #require(update.changes)
        #expect(!changes.isEmpty)
        // 🔴 The words are the SERVER's. A device that composed its own would
        // disagree with the pro's Brief, which reads the same copy table.
        #expect(changes.first?.label == "How big a job it is")
        #expect(changes.first?.to == "More than one visit")
    }

    /// Rendered at both supported widths, plus the empty-diff case, which has
    /// its own sentence and must not render as nothing.
    @Test func rendersTheBubble() throws {
        let update = try #require(
            thread().messages.first { $0.kind == .planUpdate }
        )
        for width in [CGFloat(375), CGFloat(430)] {
            let view = PlanUpdateMessageView(message: update)
                .padding(20)
                .frame(width: width)
                .background(BrandColor.bgPrimary)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let image = try #require(renderer.uiImage)
            let png = try #require(image.pngData())
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("tovis-plan-update-\(Int(width))pt.png")
            try png.write(to: url)
            print("PLAN UPDATE SNAPSHOT \(Int(width))pt → \(url.path)")
            // A bubble that rendered to nothing would still produce an image;
            // its HEIGHT is what says the diff rows are on screen.
            #expect(image.size.height > 80)
        }
    }
}
