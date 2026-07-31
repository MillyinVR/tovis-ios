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

    // MARK: - Calendar service swatches (K7 → K9)

    /// The pro-pickable SERVICE palette for calendar tiles — `--swatch-01…12`,
    /// mirrored 1:1 from `DEFAULT_CALENDAR_SWATCHES` in web `lib/brand/defaults.ts`.
    ///
    /// 🔴 A separate palette exists because every brand hue above is already
    /// semantically loaded: amber IS pending, ember IS danger, emerald IS
    /// success. A service coloured amber would read "this booking is pending".
    ///
    /// The twelve are ~30° apart and each is tuned PER MODE to the same WCAG
    /// luminance (dark ≈0.30 / light ≈0.115), so no swatch shouts louder than
    /// its neighbours and all clear the 3:1 non-text floor against every calendar
    /// background. ⚠️ The light and dark triplets are NOT the same colour — a hue
    /// that reads on ink disappears on paper. Web recomputes the contrast of
    /// these exact values in `lib/brand/defaults.test.ts` (≥5.17:1 light,
    /// ≥5.58:1 dark); these are MIRRORED, never re-picked by eye, so a change
    /// belongs in the web SSOT first.
    ///
    /// Keyed by the wire id `TovisKit.ProServiceSwatch.knownIds` narrows to.
    /// An id with no entry here paints nothing (the stripe keeps its status
    /// tone) — the same degrade web takes for a value outside its palette.
    static let calendarSwatches: [String: Color] = [
        "01": dyn(dark: (247, 101, 96),  light: (189, 21, 35)),   // coral
        "02": dyn(dark: (222, 123, 41),  light: (147, 77, 13)),   // orange
        "03": dyn(dark: (185, 143, 41),  light: (120, 91, 13)),   // ochre
        "04": dyn(dark: (136, 158, 40),  light: (86, 102, 13)),   // olive
        "05": dyn(dark: (45, 170, 94),   light: (15, 110, 56)),   // green
        "06": dyn(dark: (45, 166, 152),  light: (16, 107, 98)),   // teal
        "07": dyn(dark: (45, 162, 186),  light: (15, 104, 121)),  // cyan
        "08": dyn(dark: (44, 155, 234),  light: (15, 100, 155)),  // azure
        "09": dyn(dark: (125, 141, 245), light: (74, 61, 248)),   // periwinkle
        "10": dyn(dark: (182, 120, 245), light: (141, 25, 219)),  // violet
        "11": dyn(dark: (247, 66, 239),  light: (168, 21, 163)),  // magenta
        "12": dyn(dark: (247, 92, 163),  light: (182, 20, 109)),  // rose
    ]

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
