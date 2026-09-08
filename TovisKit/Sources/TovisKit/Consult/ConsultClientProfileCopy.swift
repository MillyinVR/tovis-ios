public enum ConsultClientProfileCopy {
    private static let descriptions: [String: [String: String]] = [
        "skinUndertone": [
            "WARM": "Golden or peachy",
            "COOL": "Pink or bluish",
            "NEUTRAL": "A mix of golden and pink shades",
            "OLIVE": "A hint of green or gray",
        ],
        "contrastLevel": [
            "LOW": "A small difference in light and dark",
            "MEDIUM": "Some difference in light and dark",
            "HIGH": "A strong difference in light and dark",
        ],
        "colorSeason": [
            "BRIGHT_SPRING": "Bright colors with golden shades",
            "TRUE_SPRING": "Colors with golden shades",
            "LIGHT_SPRING": "Light colors with golden shades",
            "LIGHT_SUMMER": "Light colors with bluish shades",
            "TRUE_SUMMER": "Colors with bluish shades",
            "SOFT_SUMMER": "Gentle, less bright colors with bluish shades",
            "SOFT_AUTUMN": "Gentle, less bright colors with golden shades",
            "TRUE_AUTUMN": "Earthy colors with golden shades",
            "DEEP_AUTUMN": "Deep colors with golden shades",
            "DEEP_WINTER": "Deep colors with bluish shades",
            "TRUE_WINTER": "Clear colors with bluish shades",
            "BRIGHT_WINTER": "Bright, clear colors with bluish shades",
        ],
        "faceProportion": [
            "WIDER": "Looks wider",
            "BALANCED": "Neither especially long nor wide",
            "LONGER": "Looks longer",
        ],
        "jawline": [
            "SOFTLY_ROUNDED": "Softly rounded",
            "BALANCED": "Between rounded and sharply defined",
            "ANGULAR": "Clearly defined angles",
        ],
        "foreheadProportion": [
            "SHORTER": "Shorter from eyebrows to hairline",
            "BALANCED": "In proportion with the rest of your face",
            "TALLER": "Taller from eyebrows to hairline",
        ],
        "featureBalance": [
            "SOFT": "Soft, rounded lines",
            "BLENDED": "A mix of soft and defined lines",
            "STRUCTURED": "Clearly defined lines",
        ],
        "eyeShape": [
            "ALMOND": "Oval with narrower corners",
            "ROUND": "Round",
            "HOODED": "The upper eyelid crease is partly covered",
            "MONOLID": "No clearly visible upper eyelid crease",
            "DOWNTURNED": "Outer corners angle slightly downward",
            "UPTURNED": "Outer corners angle slightly upward",
            "DEEP_SET": "Eyes sit farther back beneath the brow",
            "PROMINENT": "Eyes sit farther forward",
        ],
        "eyeSpacing": [
            "CLOSE_SET": "Closer together",
            "BALANCED": "About one eye’s width apart",
            "WIDE_SET": "Farther apart",
        ],
        "browDensity": [
            "SPARSE": "Fewer visible eyebrow hairs",
            "MEDIUM": "Moderately full",
            "FULL": "Full",
        ],
        "browShape": [
            "STRAIGHT": "Mostly straight",
            "SOFT_ARCH": "A gentle curve",
            "HIGH_ARCH": "A higher curve",
            "ROUNDED": "Rounded",
        ],
        "eyeColor": [
            "BROWN": "brown",
            "BLUE": "blue",
            "GREEN": "green",
            "HAZEL": "hazel",
            "GRAY": "gray",
            "MIXED": "mixed",
        ],
    ]

    public static func value(field: String, value: String) -> String {
        descriptions[field]?[value] ?? "Couldn’t tell from the photos"
    }
}
