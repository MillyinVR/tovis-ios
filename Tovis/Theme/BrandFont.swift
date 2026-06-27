import SwiftUI

/// Brand typography — the Grotesk trio from the web (`lib/brand/brand.css`):
///   • Body / UI       → Hanken Grotesk
///   • Display / titles → Space Grotesk
///   • Labels / mono    → Space Mono
///
/// TO ACTIVATE THE REAL FONTS: download the families from Google Fonts (all
/// OFL-licensed, free to bundle), drag the .ttf files into the app target, and
/// list them under `UIAppFonts` in Info.plist. Until then `Font.custom` falls
/// back to the system font automatically, so the UI still works — it just uses
/// SF instead of the brand faces. Adjust the PostScript names below to match the
/// files you add (check Font Book if unsure).
enum BrandFont {
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("HankenGrotesk-Regular", size: size).weight(weight)
    }

    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .custom("SpaceGrotesk-Medium", size: size).weight(weight)
    }

    static func mono(_ size: CGFloat) -> Font {
        .custom("SpaceMono-Regular", size: size)
    }
}
