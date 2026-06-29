// The pro top-header chrome, ported from the web `ProHeader`
// (app/pro/ProHeader.tsx + lib/brand/proOverview.css): a "◆ PRO MODE" kicker, a
// large italic page title, a notification bell (unread dot), and the account
// ("⋯") menu — plus the horizontal tab strip (`ProHeaderTabsBar`).
//
// The web header is global chrome over every pro page; on native it lives on the
// dedicated Overview home (`ProOverviewHomeView`). The account menu reuses the
// same `session.switchWorkspace`/`logout` seams as the Profile tab's account
// section (CLAUDE.md: no duplicate logic) rather than re-implementing them.
import SwiftUI
import TovisKit

struct ProTopBar: View {
    let title: String
    let hasUnread: Bool
    let onBell: () -> Void

    @State private var menuOpen = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("◆ PRO MODE")
                    .font(BrandFont.mono(10))
                    .tracking(1.6)
                    .foregroundStyle(BrandColor.accentHover)
                Text(title)
                    .font(BrandFont.display(30, .semibold))
                    .italic()
                    .foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                bell
                accountButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .sheet(isPresented: $menuOpen) { ProAccountMenuSheet() }
    }

    private var bell: some View {
        Button(action: onBell) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(BrandColor.textPrimary)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Circle().stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
                    )
                if hasUnread {
                    Circle()
                        .fill(BrandColor.accent)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(BrandColor.bgPrimary, lineWidth: 2))
                        .offset(x: -8, y: 8)
                }
            }
        }
        .accessibilityLabel("Notifications")
    }

    private var accountButton: some View {
        Button { menuOpen = true } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .frame(width: 38, height: 38)
                .background(BrandColor.bgSecondary)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
                )
        }
        .accessibilityLabel("Account menu")
    }
}

/// The horizontal scrollable tab strip (web `.brand-pro-overview-tabs`): muted
/// heavy labels, the active one in `textPrimary` with a 2px accent underline.
struct ProHeaderTabsBar: View {
    @Binding var selection: ProHeaderTab

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(ProHeaderTab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .padding(.horizontal, 20)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BrandColor.textMuted.opacity(0.10))
                .frame(height: 1)
        }
    }

    private func tabButton(_ tab: ProHeaderTab) -> some View {
        let active = tab == selection
        return Button {
            withAnimation(.easeInOut(duration: 0.16)) { selection = tab }
        } label: {
            VStack(spacing: 9) {
                Text(tab.label)
                    .font(BrandFont.body(13, .heavy))
                    .foregroundStyle(active ? BrandColor.textPrimary : BrandColor.textMuted)
                Rectangle()
                    .fill(active ? BrandColor.accent : Color.clear)
                    .frame(height: 2)
                    .clipShape(Capsule())
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// The account ("⋯") menu. A lean native port of the web `ProAccountMenu`: the
/// workspace switch + sign out (reusing the SessionModel seams). The richer
/// Studio/Content shortcut rows are reachable from the Profile tab today; this
/// sheet can grow into them later.
struct ProAccountMenuSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Button {
                        Task { await session.switchWorkspace(to: .client) }
                        dismiss()
                    } label: {
                        BrandSurface {
                            HStack(spacing: 12) {
                                Image(systemName: "person.2")
                                    .font(.system(size: 18))
                                    .foregroundStyle(BrandColor.accent)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Switch to client")
                                        .font(BrandFont.body(15, .semibold))
                                        .foregroundStyle(BrandColor.textPrimary)
                                    Text("Browse & book as a client")
                                        .font(BrandFont.body(12))
                                        .foregroundStyle(BrandColor.textMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(BrandColor.textMuted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(session.isWorking)

                    if let message = session.errorMessage {
                        Text(message)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.ember)
                    }

                    Button(role: .destructive) {
                        Task { await session.logout() }
                    } label: {
                        Text("Sign out")
                            .font(BrandFont.body(16, .semibold))
                            .foregroundStyle(BrandColor.ember)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(BrandColor.ember.opacity(0.4), lineWidth: 1)
                            )
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(BrandColor.textSecondary)
                }
            }
        }
        .tint(BrandColor.accent)
        .presentationDetents([.medium])
    }
}
