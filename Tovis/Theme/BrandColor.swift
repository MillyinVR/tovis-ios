import SwiftUI
import UIKit

/// The Tovis "Peacock Plume" palette, ported 1:1 from the web brand source
/// (`lib/brand/brands/tovis.ts`). Every color adapts to light/dark automatically
/// — dark is the brand default. RGB triplets match the web tokens exactly.
enum BrandColor {
    // Backgrounds (ink canvas in dark, paper in light)
    static let bgPrimary   = dyn(dark: (10, 20, 19),    light: (243, 240, 231))
    static let bgSecondary = dyn(dark: (14, 26, 24),    light: (236, 232, 221))
    static let bgSurface   = dyn(dark: (17, 32, 30),    light: (255, 255, 255))

    // Text
    static let textPrimary   = dyn(dark: (242, 239, 231), light: (10, 20, 19))
    static let textSecondary = dyn(dark: (199, 210, 207), light: (58, 74, 70))
    static let textMuted     = dyn(dark: (143, 163, 158), light: (98, 115, 110))

    // Accents
    static let accent       = dyn(dark: (21, 201, 168), light: (14, 155, 134))  // Plume Teal
    static let accentHover  = dyn(dark: (47, 224, 190), light: (11, 122, 107))
    static let gold         = dyn(dark: (242, 180, 62), light: (183, 131, 31))  // Plume Gold
    static let onAccent     = dyn(dark: (10, 20, 19),   light: (255, 255, 255)) // text on teal/gold

    // Semantic
    static let iris    = dyn(dark: (107, 75, 230), light: (91, 60, 214))  // saves / pop
    static let emerald = dyn(dark: (14, 142, 137), light: (11, 111, 102)) // success
    static let ember   = dyn(dark: (255, 61, 110), light: (225, 29, 84))  // danger / like
    static let amber   = dyn(dark: (242, 180, 62), light: (183, 131, 31)) // warn / pending

    private static func dyn(dark: (Int, Int, Int), light: (Int, Int, Int)) -> Color {
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat(c.0) / 255,
                green: CGFloat(c.1) / 255,
                blue: CGFloat(c.2) / 255,
                alpha: 1
            )
        })
    }
}
