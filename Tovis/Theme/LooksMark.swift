// The footer's raised center "Looks" mark — ported from the web's
// `footer/LooksMark.tsx` → `TovisFeatherMark.tsx` → `RingCoin.tsx`.
//
// An iridescent plume ring wraps a dark, sphere-shaded "app-coin"; inside sits
// the tovis feather (the Eye, reused from TovisEye). Values mirror the web CSS
// 1:1 so the mark reads identically on both platforms.
import SwiftUI

struct LooksMark: View {
    var size: CGFloat = 66

    // Drives the soft orb's slow diagonal drift (web @keyframes tovisOrb).
    @State private var orbDrift = false

    // A little see-through so the footer + content read faintly behind the coin.
    private static let coinOpacity: Double = 0.82

    // --plume: linear-gradient(100deg, #f2b43e, #15c9a8 32%, #0e8e89 50%,
    //          #1574c4 72%, #6b4be6)
    private static let plume = LinearGradient(
        stops: [
            .init(color: Color(hex: 0xF2B43E), location: 0.00),
            .init(color: Color(hex: 0x15C9A8), location: 0.32),
            .init(color: Color(hex: 0x0E8E89), location: 0.50),
            .init(color: Color(hex: 0x1574C4), location: 0.72),
            .init(color: Color(hex: 0x6B4BE6), location: 1.00),
        ],
        // 100deg ≈ left→right with a slight downward tilt.
        startPoint: UnitPoint(x: 0.0, y: 0.32),
        endPoint: UnitPoint(x: 1.0, y: 0.68)
    )

    // --tovis-coin: radial-gradient(125% 125% at 32% 24%, #2c4f49 0%,
    //               #16302b 27%, #0d1a17 58%, #050d0b 100%)
    private var coin: some View {
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

    // Soft radiating orb — warm gold into teal/green, fully diffused edges —
    // screen-blended over the coin so it reads as luminous translucency. Drifts
    // diagonally like the web's `tovisOrb` animation.
    private func orb(_ inner: CGFloat) -> some View {
        let start = CGSize(width: -inner * 0.42, height: -inner * 0.26)
        let end = CGSize(width: inner * 0.50, height: inner * 0.40)
        return RadialGradient(
            stops: [
                .init(color: Color(red: 1.000, green: 0.953, blue: 0.792).opacity(0.46), location: 0.00),
                .init(color: Color(red: 0.976, green: 0.847, blue: 0.525).opacity(0.36), location: 0.19),
                .init(color: Color(red: 0.478, green: 0.886, blue: 0.737).opacity(0.30), location: 0.40),
                .init(color: Color(red: 0.361, green: 0.816, blue: 0.690).opacity(0.12), location: 0.60),
                .init(color: .clear, location: 0.80),
            ],
            center: .center, startRadius: 0, endRadius: inner * 0.44
        )
        .frame(width: inner * 0.88, height: inner * 0.88)
        .blendMode(.screen)
        .offset(orbDrift ? end : start)
        .animation(.easeInOut(duration: 7.2).repeatForever(autoreverses: true), value: orbDrift)
        .onAppear { orbDrift = true }
        .allowsHitTesting(false)
    }

    var body: some View {
        // ring padding: max(2.5, size * 0.045)
        let ringWidth = max(2.5, size * 0.045)
        let featherSize = size * 0.66

        let innerSize = size - ringWidth * 2

        ZStack {
            coin.opacity(Self.coinOpacity)   // a little transparency
            TovisEye(size: featherSize)
            // A soft jewel-tinted orb of light over the coin with a screen blend
            // (web TovisFeatherMark's radiating orb), drifting diagonally.
            orb(innerSize)
        }
        .frame(width: innerSize, height: innerSize)
        .clipShape(Circle())
        .padding(ringWidth)
        // Plume as a RING (stroke), not a filled disc — so nothing opaque sits
        // behind the translucent coin and the footer/content shows through.
        .overlay(Circle().strokeBorder(Self.plume, lineWidth: ringWidth))
        // boxShadow: 0 14px 30px var(--tovis-acc-shadow) (accent @ 0.45)
        .shadow(color: BrandColor.accent.opacity(0.45), radius: 15, x: 0, y: 14)
        .frame(width: size, height: size)
        .accessibilityLabel("Looks")
    }
}

/// Small hex initializer so the ported web color literals read 1:1.
extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

#Preview {
    ZStack {
        BrandColor.bgSurface.ignoresSafeArea()
        LooksMark(size: 66)
    }
}