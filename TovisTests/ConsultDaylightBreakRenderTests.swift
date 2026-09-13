// The daylight break (Tori, 2026-09-12), rendered to PNGs a person can look at.
//
// 🔴 Why a render test and not only an assertion: the two views this covers are
// the ONLY new layouts in the parity pass, and every defect this repo has caught
// in a thread card — a swallowed button, a sentence clipped at 375pt, a control
// the same colour as what it sits on — was invisible to a test that asserts on
// text. What it does NOT claim: that either card was reached by tapping through
// the app. It renders the view, not the navigation.
import Foundation
import SwiftUI
import Testing
import TovisKit
import UIKit
@testable import Tovis

@MainActor
@Suite struct ConsultDaylightBreakRenderTests {
    private func render(
        _ view: some View, name: String, width: CGFloat, dark: Bool
    ) throws -> UIImage {
        let renderer = ImageRenderer(
            content: view
                .padding(20)
                .frame(width: width)
                .background(BrandColor.bgPrimary)
                .environment(\.colorScheme, dark ? .dark : .light)
        )
        renderer.scale = 3
        let image = try #require(renderer.uiImage)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tovis-daylight-\(name)-\(Int(width))pt-\(dark ? "dark" : "light").png"
            )
        try #require(image.pngData()).write(to: url)
        print("DAYLIGHT SNAPSHOT \(name) \(Int(width))pt \(dark ? "dark" : "light") → \(url.path)")
        return image
    }

    /// The choice: the app's sentence, then both buttons. Rendered at both
    /// supported widths and in both modes.
    @Test func rendersTheChoice() throws {
        for width in [CGFloat(375), CGFloat(430)] {
            for dark in [false, true] {
                let image = try render(
                    ConsultDaylightChoiceView(
                        busy: false, onBuildNow: {}, onAddPhotosFirst: {}
                    ),
                    name: "choice", width: width, dark: dark
                )
                // 🔴 `ImageRenderer` reports POINTS; `scale` changes the
                // backing store, not `size`. Asserting pixels here passed for
                // the wrong reason on nothing and failed on everything.
                #expect(image.size.width == width)
                // The bubble runs to several lines and the two buttons add
                // ~100pt under it. A card that swallowed one of them comes in
                // far short of this — that is what the height is watching for.
                #expect(image.size.height > 250)
            }
        }
    }

    /// The compact row, in both of its states: the first one carries her answer
    /// and the standing invitation, the rest are one line each.
    @Test func rendersTheCompactRow() throws {
        let first = try render(
            ConsultDaylightLaterView(
                title: "The back of your hair", shootable: true,
                sheSaidBuildNow: true, busy: false, onAdd: {}
            ),
            name: "later-first", width: 375, dark: false
        )
        let rest = try render(
            ConsultDaylightLaterView(
                title: "The back of your hair", shootable: true,
                sheSaidBuildNow: false, busy: false, onAdd: {}
            ),
            name: "later-rest", width: 375, dark: false
        )
        // The first carries two bubbles the others do not.
        #expect(first.size.height > rest.size.height + 100)
        // One line, not a camera card: the plain row stays short.
        #expect(rest.size.height < 100)

        // 🔴 A shot the SERVER would refuse offers no way in — but the row is
        // still drawn, so she can see the photo is still wanted.
        let refused = try render(
            ConsultDaylightLaterView(
                title: "The back of your hair", shootable: false,
                sheSaidBuildNow: false, busy: false, onAdd: {}
            ),
            name: "later-not-shootable", width: 375, dark: false
        )
        #expect(refused.size.height > 0)
        #expect(refused.size.height <= rest.size.height)
    }
}
