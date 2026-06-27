import SwiftUI

/// Brand typography — the Grotesk trio from the web (`lib/brand/brand.css`):
///   • Body / UI       → Hanken Grotesk
///   • Display / titles → Space Grotesk
///   • Labels / mono    → Space Mono
///
/// The font files live in `Tovis/Fonts/` and are registered via `UIAppFonts` in
/// Info.plist. Hanken Grotesk and Space Grotesk are variable fonts referenced by
/// FAMILY name so `.weight()` drives the weight axis; Space Mono ships static
/// Regular + Bold. `Font.custom` falls back to the system font if a family is
/// missing, so nothing breaks if a file is ever removed.
enum BrandFont {
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Hanken Grotesk", size: size).weight(weight)
    }

    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .custom("Space Grotesk", size: size).weight(weight)
    }

    static func mono(_ size: CGFloat) -> Font {
        .custom("Space Mono", size: size)
    }
}
