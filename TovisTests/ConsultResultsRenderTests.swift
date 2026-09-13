// The whole-plan screen — the device's twin of the web results page.
//
// 🔴 Every section here was DECODED on the device and rendered nowhere before
// this screen existed, so there is no prior behaviour to regress against and
// nothing but a render says whether it reads. The PNGs are written to a path
// the test prints; the height assertions are the part CI can check.
import Foundation
import SwiftUI
import Testing
import TovisKit
import UIKit
@testable import Tovis

@MainActor
@Suite struct ConsultResultsRenderTests {
    private func results() throws -> ConsultClientResults {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TovisKit/Tests/TovisKitTests/Fixtures/consultFlow.json")
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let envelope = try #require(root["results"] as? [String: Any])
        let payload = try #require(envelope["results"] as? [String: Any])
        return try JSONDecoder().decode(
            ConsultClientResults.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    /// 🔴 Render ORDER is a contract (`ConsultResultPresentation.sections`), not
    /// incidental SwiftUI source order — and the client's own words come before
    /// anything a model observed. The screen walks that list rather than
    /// hard-coding a sequence beside it, so this asserts the list itself.
    @Test func theSectionOrderIsTheDeclaredContract() {
        #expect(ConsultResultPresentation.sections == [
            .clientWords, .aiObservations, .featureProfile, .styleDirections,
            .safety, .achievability, .directions, .lockedMeCard,
        ])
        // Every declared section has a case in the screen's switch — a case
        // added to the enum and forgotten in the view would render nothing.
        #expect(Set(ConsultResultPresentation.sections) == Set(ConsultResultSection.allCases))
    }

    /// 🔴 Renders `ConsultResultsContent`, NOT `ConsultResultsView`.
    /// `ImageRenderer` draws a `ScrollView` as its background and nothing else:
    /// the first version of this test rendered the screen, got back 780×5200
    /// pixels of ONE colour, and passed — because it asserted the width. Hence
    /// `distinctColours` below, which is the assertion that would have caught it.
    @Test func rendersTheWholePlan() throws {
        let results = try results()
        for (dark, name) in [(false, "light"), (true, "dark")] {
            let view = ConsultResultsContent(
                results: results, teaserTapped: false, busy: false, onTapMeCard: {}
            )
            .frame(width: 390)
            .background(BrandColor.bgPrimary)
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.uiImage)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("tovis-consult-results-\(name).png")
            try #require(image.pngData()).write(to: url)
            print("RESULTS SNAPSHOT \(name) → \(url.path) (\(Int(image.size.height))pt)")
            #expect(image.size.width == 390)
            // Eight sections of text and tiles. A blank page is one colour.
            #expect(image.size.height > 1200)
            #expect(distinctColours(image) > 50)
        }
    }

    /// How many distinct pixel values the render actually contains. A view that
    /// drew nothing still produces a perfectly valid image of its background.
    private func distinctColours(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Set(pixels).count
    }

    /// 🔴 The safety section is ALWAYS drawn, including when there is nothing in
    /// it: an empty one is a statement, and hiding it would read as a clean bill
    /// of health nobody gave. The fixture's own flags decide which sentence.
    @Test func theSafetySectionSpeaksEvenWhenEmpty() throws {
        #expect(!ConsultResultsCopy.safetyEmpty.isEmpty)
        #expect(ConsultResultsCopy.safetyItemSuffix.contains("professional"))
        // UNKNOWN and REQUIRES_PRO_ASSESSMENT deliberately say the same thing —
        // "unknown" is not something the client can act on.
        #expect(
            ConsultResultsCopy.achievabilityLabel("UNKNOWN")
                == ConsultResultsCopy.achievabilityLabel("REQUIRES_PRO_ASSESSMENT")
        )
        // A level is a COLOUR, never a colourist's number.
        #expect(ConsultResultsCopy.hairLevel("LEVEL_5") == "medium brown")
        #expect(ConsultResultsCopy.hairLevel("UNKNOWN") == ConsultResultsCopy.unknownLabel)
        #expect(!ConsultResultsCopy.hairLevel("LEVEL_5").contains("Level"))
    }
}
