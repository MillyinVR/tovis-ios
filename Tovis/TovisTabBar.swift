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
                FooterNavItemLabel(
                    systemImage: tab.systemImage,
                    label: tab.label,
                    active: isActive,
                    badge: badge(for: tab)
                )
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