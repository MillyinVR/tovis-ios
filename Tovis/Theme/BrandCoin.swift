// The raised footer "app-coin" — an iridescent ring wrapping a dark, sphere-
// shaded coin, with arbitrary content inside. Extracted from `LooksMark` so the
// client center (the feather) and the PRO center (the live-session button) share
// ONE coin/ring/shadow definition instead of each re-deriving the gradients
// (CLAUDE.md: no duplicate logic). Values mirror the web CSS 1:1.
import SwiftUI

/// Which ring gradient wraps the coin.
///   `.plume` — the brand-constant iridescent plume (idle, like the Looks mark).
///   `.cta`   — the live/active CTA accent gradient (web `var(--cta)`).
enum BrandRing { case plume, cta }

struct BrandCoin<Content: View>: View {
    var size: CGFloat
    var ring: BrandRing = .plume
    /// A little see-through so the footer + content read faintly behind the coin.
    var coinOpacity: Double = 0.82
    @ViewBuilder var content: () -> Content

    // --plume: linear-gradient(100deg, #f2b43e, #15c9a8 32%, #0e8e89 50%,
    //          #1574c4 72%, #6b4be6)
    static var plume: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(hex: 0xF2B43E), location: 0.00),
                .init(color: Color(hex: 0x15C9A8), location: 0.32),
                .init(color: Color(hex: 0x0E8E89), location: 0.50),
                .init(color: Color(hex: 0x1574C4), location: 0.72),
                .init(color: Color(hex: 0x6B4BE6), location: 1.00),
            ],
            startPoint: UnitPoint(x: 0.0, y: 0.32),
            endPoint: UnitPoint(x: 1.0, y: 0.68)
        )
    }

    // --cta: the tenant CTA gradient. For Tovis it reads as Plume Teal → Gold —
    // the accent-forward live state of the center button.
    static var cta: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0x15C9A8), Color(hex: 0xF2B43E)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // --tovis-coin: radial-gradient(125% 125% at 32% 24%, #2c4f49 0%,
    //               #16302b 27%, #0d1a17 58%, #050d0b 100%)
    private func coin(_ size: CGFloat) -> some View {
        RadialGradient(
            stops: [
                .init(color: Color(hex: 0x2C4F49), location: 0.00),
                .init(color: Color(hex: 0x16302B), location: 0.27),
                .init(color: Color(hex: 0x0D1A17), location: 0.58),
                .init(color: Color(hex: 0x050D0B), location: 1.00),
            ],
            center: UnitPoint(x: 0.32, y: 0.24),
            startRadius: 0,
            endRadius: size * 0.9
        )
    }

    var body: some View {
        // ring padding: max(2.5, size * 0.045)
        let ringWidth = max(2.5, size * 0.045)
        let innerSize = size - ringWidth * 2

        ZStack {
            coin(size).opacity(coinOpacity)
            content()
        }
        .frame(width: innerSize, height: innerSize)
        .clipShape(Circle())
        .padding(ringWidth)
        // Plume/CTA as a RING (stroke), not a filled disc — so nothing opaque
        // sits behind the translucent coin and the footer/content shows through.
        .overlay(Circle().strokeBorder(ring == .cta ? Self.cta : Self.plume, lineWidth: ringWidth))
        // boxShadow: 0 14px 30px var(--tovis-acc-shadow) (accent @ 0.45)
        .shadow(color: BrandColor.accent.opacity(0.45), radius: 15, x: 0, y: 14)
        .frame(width: size, height: size)
    }
}
