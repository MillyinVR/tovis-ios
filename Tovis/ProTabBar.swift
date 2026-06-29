// The signed-in PRO footer — a native rebuild of the web's `ProSessionFooter`.
//
// Same five slots as the web bar: Looks · Calendar · [live-session center] ·
// Messages · Profile — same raised coin, mono-uppercase labels, and active dot —
// so a pro moving between web and iOS sees the exact same bar. The four nav items
// reuse the shared `FooterNavItemLabel`/`FooterBadgeDot` (no fork of the client
// bar). The center is the live-session button driven by `ProSessionModel`.
import SwiftUI

struct ProTabBar: View {
    @Binding var selected: ProTab.ID
    /// The live-session state machine (center button).
    let session: ProSessionModel
    /// Unread Messages badge text (e.g. "3", "9+"). Nil → no badge.
    var messagesBadge: String? = nil

    // Tunable footer geometry — identical to the client bar.
    private let barHeight: CGFloat = 68
    private let centerSize: CGFloat = 84
    private let centerBottomGap: CGFloat = 8

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(ProNav.tabs) { tab in
                item(for: tab)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(minHeight: barHeight, alignment: .top)
        // The raised center button is anchored to the bar's BOTTOM and overflows
        // upward so it pokes slightly above the top edge (web .tovis-center-lift).
        .overlay(alignment: .bottom) {
            ProSessionCenterButton(session: session, size: centerSize)
                .offset(y: -centerBottomGap)
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
    private func item(for tab: ProTab) -> some View {
        let isActive = selected == tab.id

        Button {
            selected = tab.id
        } label: {
            if tab.id == .looks {
                // Web renders the Looks tab with `<BrandMark size={22}/>` (the
                // brand Eye), not a lucide glyph — mirror that so the pro footer's
                // Looks icon is the signature mark, matching the web bar 1:1.
                FooterNavItemLabel(
                    label: tab.label,
                    active: isActive,
                    badge: badge(for: tab)
                ) {
                    // 24 to match the native sibling glyphs (web uses 22 for both
                    // BrandMark and the lucide icons; native symbols render at 24,
                    // so the Eye matches them to keep the bar internally balanced).
                    TovisEye(size: 24)
                }
            } else {
                FooterNavItemLabel(
                    systemImage: tab.systemImage,
                    label: tab.label,
                    active: isActive,
                    badge: badge(for: tab)
                )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private func badge(for tab: ProTab) -> String? {
        guard tab.hasBadge, let text = messagesBadge?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty else { return nil }
        return text
    }
}

/// The raised live-session center button. Ported from `ProSessionFooter`'s center
/// button: the shared `BrandCoin` (CTA ring when live, plume when idle) shows the
/// mono action label or a camera glyph; a pulse ring radiates when live, and an
/// eligible-booking count badge appears in the UPCOMING_PICKER mode.
struct ProSessionCenterButton: View {
    let session: ProSessionModel
    var size: CGFloat = 84

    @State private var pulse = false

    var body: some View {
        ZStack {
            // Pulsing halo when there's a live/upcoming session (web tovisPulse).
            if session.isLive {
                Circle()
                    .fill(BrandColor.accent)
                    .frame(width: size * 0.86, height: size * 0.86)
                    .scaleEffect(pulse ? 1.18 : 0.9)
                    .opacity(pulse ? 0.0 : 0.45)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false), value: pulse)
                    .onAppear { pulse = true }
                    .allowsHitTesting(false)
            }

            Button {
                Task { await session.handleCenterClick() }
            } label: {
                BrandCoin(size: size, ring: session.isLive ? .cta : .plume) {
                    Group {
                        if session.showsCamera {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 22, weight: .semibold))
                        } else {
                            Text(session.label.uppercased())
                                .font(BrandFont.mono(12))
                                .fontWeight(.bold)
                                .tracking(0.5)
                                .minimumScaleFactor(0.7)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                        }
                    }
                    .foregroundStyle(BrandColor.accent)
                }
                // count badge in the UPCOMING_PICKER mode
                .overlay(alignment: .topTrailing) {
                    if session.pickerCount > 1 {
                        Text("\(session.pickerCount)")
                            .font(BrandFont.mono(10))
                            .fontWeight(.bold)
                            .foregroundStyle(BrandColor.onAccent)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(BrandColor.accent)
                            .clipShape(Circle())
                            .overlay(Circle().strokeBorder(BrandColor.bgSurface, lineWidth: 2))
                            .offset(x: -2, y: 2)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(session.centerDisabled)
            .opacity(session.centerDisabled ? 0.5 : 1)
            .accessibilityLabel(session.showsCamera ? "Open camera" : session.label)
        }
    }
}
