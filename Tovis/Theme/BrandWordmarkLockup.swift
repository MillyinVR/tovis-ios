import SwiftUI

/// The brand's primary lockup: the Eye beside the lowercase wordmark.
///
/// The native counterpart of web's `BrandWordmark` (`lib/brand/BrandWordmark.tsx`),
/// which sets "tovis" in the display face with the Eye replacing the i-dot —
/// the brand sheet's "the dot is the light" mark. Rendering the name as plain
/// text is not the mark, and the two clients showing different things in the
/// same band is the kind of drift a shared component exists to stop.
///
/// The Eye sits BESIDE the word rather than inside it: SwiftUI has no reliable
/// way to register a glyph over the i-dot across dynamic-type sizes, and a mark
/// that drifts off its dot at one text size is worse than one that never claimed
/// to be there.
struct BrandWordmarkLockup: View {
    /// Font size of the wordmark, in points. The Eye scales from it.
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: size * 0.26) {
            TovisEye(size: size * 0.95)
            Text(TovisBrand.displayName.lowercased())
                .font(BrandFont.display(size, .bold))
                .tracking(-size * 0.045)
                .foregroundStyle(BrandColor.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TovisBrand.displayName)
    }
}
