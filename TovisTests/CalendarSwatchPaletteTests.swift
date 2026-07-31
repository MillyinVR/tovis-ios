import Testing
import TovisKit
import UIKit
@testable import Tovis

// The calendar SERVICE swatch palette (K9) — `BrandColor.calendarSwatches` and
// the `calendarSwatchTone` seam that reads it.
//
// The twelve hues are MIRRORED from web's `DEFAULT_CALENDAR_SWATCHES`
// (tovis-app `lib/brand/defaults.ts`), never re-picked by eye, so a pro who
// colours a service sees the same colour on both platforms. Web proves those
// values by RECOMPUTING their contrast (`lib/brand/defaults.test.ts`) rather
// than trusting the comment beside them; this does the same on device, because
// a mirrored constant is only as good as the transcription — a digit dropped
// between the two repos is invisible to every other test here.
@Suite struct CalendarSwatchPaletteTests {

    /// Every background a calendar tile can sit on. The stripe is a 3pt bar with
    /// no text, so the bar that matters is the 3:1 NON-TEXT floor (WCAG 1.4.11),
    /// not 4.5:1.
    private static let backgrounds: [(String, UIColor)] = [
        ("bgPrimary", UIColor(BrandColor.bgPrimary)),
        ("bgSecondary", UIColor(BrandColor.bgSecondary)),
        ("bgSurface", UIColor(BrandColor.bgSurface)),
    ]

    private static let modes: [(String, UITraitCollection)] = [
        ("dark", UITraitCollection(userInterfaceStyle: .dark)),
        ("light", UITraitCollection(userInterfaceStyle: .light)),
    ]

    // MARK: - Colour math (WCAG 2.x)

    private func components(_ color: UIColor, _ traits: UITraitCollection)
        -> (r: CGFloat, g: CGFloat, b: CGFloat)
    {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
    }

    private func relativeLuminance(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        func linear(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }

    private func contrast(_ a: UIColor, _ b: UIColor, _ traits: UITraitCollection) -> CGFloat {
        let la = relativeLuminance(components(a, traits))
        let lb = relativeLuminance(components(b, traits))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func rgb255(_ color: UIColor, _ traits: UITraitCollection) -> [Int] {
        let c = components(color, traits)
        return [c.r, c.g, c.b].map { Int(($0 * 255).rounded()) }
    }

    // MARK: - The list

    @Test("the palette defines exactly the ids the wire model narrows to")
    func paletteCoversEveryKnownId() {
        // Two lists in two modules: TovisKit validates the wire, the app paints
        // it. A 13th swatch added to one and not the other would silently paint
        // nothing — the degrade is safe, but it is not what anyone intended.
        #expect(Set(BrandColor.calendarSwatches.keys) == Set(ProServiceSwatch.knownIds))
        #expect(BrandColor.calendarSwatches.count == 12)
    }

    @Test("an unpaintable id claims no colour at all")
    func unknownIdsResolveToNil() {
        // nil — NOT a fallback hue. The caller keeps the status tone, because a
        // substituted colour would misreport which service the booking is.
        #expect(calendarSwatchTone(nil) == nil)
        #expect(calendarSwatchTone("13") == nil)
        #expect(calendarSwatchTone("9") == nil)     // an id is a token name, not a number
        #expect(calendarSwatchTone("") == nil)
        #expect(calendarSwatchTone("09") != nil)
    }

    // MARK: - The values

    @Test("every swatch is a per-mode PAIR, not one triplet reused")
    func swatchesDifferBetweenModes() {
        // A hue tuned to read on ink is too dark to read on paper (and vice
        // versa). If a transcription collapsed a pair to one value, this is what
        // notices — the colour would still render, just illegibly in one mode.
        for id in ProServiceSwatch.knownIds {
            let color = UIColor(BrandColor.calendarSwatches[id]!)
            let dark = rgb255(color, Self.modes[0].1)
            let light = rgb255(color, Self.modes[1].1)
            #expect(dark != light, "swatch \(id) is the same colour in both modes: \(dark)")
        }
    }

    @Test("the twelve are distinguishable from each other in both modes")
    func swatchesAreDistinct() {
        for (name, traits) in Self.modes {
            let values = ProServiceSwatch.knownIds.map {
                rgb255(UIColor(BrandColor.calendarSwatches[$0]!), traits)
            }
            #expect(Set(values.map(\.description)).count == 12, "duplicate swatch in \(name)")
        }
    }

    @Test("every swatch clears the 3:1 non-text floor on every calendar background")
    func swatchesClearContrastFloor() {
        for id in ProServiceSwatch.knownIds {
            let color = UIColor(BrandColor.calendarSwatches[id]!)
            for (modeName, traits) in Self.modes {
                for (bgName, background) in Self.backgrounds {
                    let ratio = contrast(color, background, traits)
                    #expect(
                        ratio >= 3.0,
                        "swatch \(id) on \(bgName) in \(modeName) is \(ratio):1"
                    )
                }
            }
        }
    }

    @Test("the mirrored triplets match web's DEFAULT_CALENDAR_SWATCHES")
    func tripletsMatchTheWebSource() {
        // Spot-pins, not the whole table (that would just be the table twice):
        // the two ends of the picker plus the one a pro has actually used in dev.
        // A wholesale re-transcription would still be caught by the contrast and
        // distinctness tests above; these catch a single transposed digit.
        let expected: [String: (dark: [Int], light: [Int])] = [
            "01": (dark: [247, 101, 96], light: [189, 21, 35]),
            "02": (dark: [222, 123, 41], light: [147, 77, 13]),
            "09": (dark: [125, 141, 245], light: [74, 61, 248]),
            "12": (dark: [247, 92, 163], light: [182, 20, 109]),
        ]

        for (id, want) in expected {
            let color = UIColor(BrandColor.calendarSwatches[id]!)
            #expect(rgb255(color, Self.modes[0].1) == want.dark, "swatch \(id) dark")
            #expect(rgb255(color, Self.modes[1].1) == want.light, "swatch \(id) light")
        }
    }
}
