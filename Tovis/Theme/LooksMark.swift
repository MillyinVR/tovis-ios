// The footer's raised center "Looks" mark — ported from the web's
// `footer/LooksMark.tsx` → `TovisFeatherMark.tsx` → `RingCoin.tsx`.
//
// An iridescent plume ring wraps a dark, sphere-shaded "app-coin" (now the shared
// `BrandCoin`); inside sits the tovis feather (the Eye, reused from TovisEye) plus
// a softly drifting orb of light. Values mirror the web CSS 1:1.
import SwiftUI

struct LooksMark: View {
    var size: CGFloat = 66

    // Drives the soft orb's slow diagonal drift (web @keyframes tovisOrb).
    @State private var orbDrift = false

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
        let ringWidth = max(2.5, size * 0.045)
        let innerSize = size - ringWidth * 2
        let featherSize = size * 0.66

        BrandCoin(size: size, ring: .plume) {
            ZStack {
                TovisEye(size: featherSize)
                orb(innerSize)
            }
        }
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
