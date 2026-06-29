// Shared footer building blocks, used by BOTH the client bar (`TovisTabBar`) and
// the pro bar (`ProTabBar`) so the two stay pixel-identical and we don't fork the
// rendering (CLAUDE.md: no duplicate logic). Mirrors the web `FooterNavItem.tsx`
// + `BadgeDot.tsx` (shared there too).
import SwiftUI

/// One bottom-nav item: small accent dot (active), icon, mono-uppercase label.
struct FooterNavItemLabel: View {
    let systemImage: String
    let label: String
    let active: Bool
    var badge: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .regular))   // web: lucide size={24}
                    .foregroundStyle(active ? BrandColor.accent : BrandColor.textMuted)
                    .frame(width: 28, height: 26)
                    // active dot floats above the icon (web: absolute, top: -9 —
                    // doesn't take a row, so the icon row sits where web's does).
                    .overlay(alignment: .top) {
                        Circle()
                            .fill(BrandColor.accent)
                            .frame(width: 5, height: 5)
                            .offset(y: -9)
                            .opacity(active ? 1 : 0)
                    }

                if let badge {
                    FooterBadgeDot(label: badge)
                        .alignmentGuide(.top) { $0[.top] + 6 }
                        .alignmentGuide(.trailing) { $0[.trailing] - 8 }
                }
            }

            Text(label.uppercased())
                .font(BrandFont.mono(9))
                .tracking(0.6)
                .foregroundStyle(active ? BrandColor.textPrimary : BrandColor.textMuted)
        }
        .contentShape(Rectangle())
    }
}

/// The accent unread pill — mirrors `BadgeDot.tsx`.
struct FooterBadgeDot: View {
    let label: String

    var body: some View {
        Text(label)
            .font(BrandFont.mono(10))
            .foregroundStyle(BrandColor.onAccent)
            .padding(.horizontal, 5)
            .frame(minWidth: 16, minHeight: 16)
            .background(BrandColor.accent)
            .clipShape(Capsule())
            .accessibilityLabel("\(label) unread")
    }
}
