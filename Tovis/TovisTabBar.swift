// The signed-in client footer — a native rebuild of the web's
// `ClientSessionFooter` (+ `FooterNavItem`, `BadgeDot`, `styles/footers.css`).
//
// Same five tabs, same raised feather center, same mono-uppercase labels and the
// little accent "active dot" — so a user moving between web and iOS sees the
// exact same bar. Selection is driven from MainTabView.
import SwiftUI

struct TovisTabBar: View {
    @Binding var selected: ClientTab.ID
    /// Unread Inbox badge text (e.g. "3", "9+"). Nil → no badge, matching web.
    var messagesBadge: String? = nil

    // Tunable footer geometry.
    private let barHeight: CGFloat = 68      // shorter bar (was 80)
    private let centerSize: CGFloat = 84     // bigger center coin (was 72)
    private let centerBottomGap: CGFloat = 8 // coin's gap above the bar bottom

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(ClientNav.tabs) { tab in
                item(for: tab)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(minHeight: barHeight, alignment: .top)
        // The raised center button is anchored to the bar's BOTTOM (sits low,
        // close to the footer bottom but not touching) and overflows upward so
        // it still pokes slightly above the top edge.
        .overlay(alignment: .bottom) {
            Button {
                selected = .looks
            } label: {
                LooksMark(size: centerSize)
                    .offset(y: -centerBottomGap)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Looks")
            .accessibilityAddTraits(selected == .looks ? [.isSelected] : [])
        }
        // surface + hairline top border (--bg-surface / --line)
        .background(
            BrandColor.bgSurface
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(BrandColor.textMuted.opacity(0.12))
                        .frame(height: 1)
                }
                .ignoresSafeArea(.container, edges: .bottom)
        )
    }

    @ViewBuilder
    private func item(for tab: ClientTab) -> some View {
        let isActive = selected == tab.id

        if tab.center {
            // The real button is the bottom-anchored overlay above; this is just
            // an empty slot that reserves the center's horizontal space so the
            // four nav items space evenly (2 left, 2 right).
            Color.clear.frame(height: 1)
        } else {
            Button {
                selected = tab.id
            } label: {
                NavItemLabel(tab: tab, active: isActive, badge: badge(for: tab))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.label)
            .accessibilityAddTraits(isActive ? [.isSelected] : [])
        }
    }

    private func badge(for tab: ClientTab) -> String? {
        guard tab.hasBadge, let text = messagesBadge?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty else { return nil }
        return text
    }
}

/// One bottom-nav item: small accent dot (active), icon, mono-uppercase label —
/// mirrors `FooterNavItem.tsx`.
private struct NavItemLabel: View {
    let tab: ClientTab
    let active: Bool
    var badge: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: tab.systemImage)
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
                    BadgeDot(label: badge)
                        .alignmentGuide(.top) { $0[.top] + 6 }
                        .alignmentGuide(.trailing) { $0[.trailing] - 8 }
                }
            }

            Text(tab.label.uppercased())
                .font(BrandFont.mono(9))
                .tracking(0.6)
                .foregroundStyle(active ? BrandColor.textPrimary : BrandColor.textMuted)
        }
        .contentShape(Rectangle())
    }
}

/// The accent unread pill — mirrors `BadgeDot.tsx`.
private struct BadgeDot: View {
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

#Preview {
    struct Demo: View {
        @State private var sel: ClientTab.ID = .home
        var body: some View {
            VStack {
                Spacer()
                TovisTabBar(selected: $sel, messagesBadge: "3")
            }
            .background(BrandColor.bgPrimary)
        }
    }
    return Demo()
}