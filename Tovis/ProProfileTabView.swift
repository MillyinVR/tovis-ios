// Pro Profile tab — the footer's slot-5 destination (web
// `/pro/profile/public-profile`). v1 is the account surface: identity, theme,
// **switch to the client workspace** (the cross-device parity seam — re-mints the
// JWT acting role server-side), and sign out. Full public-profile management
// (offerings · portfolio · bio editing) is a later phase — see HANDOFF.
import SwiftUI
import TovisKit

struct ProProfileTabView: View {
    @Environment(SessionModel.self) private var session
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    BrandSection(title: "Workspace") {
                        VStack(spacing: 10) {
                            // Every pro account is also a client — switching re-mints
                            // the token's acting role and swaps the shell.
                            Button {
                                Task { await session.switchWorkspace(to: .client) }
                            } label: {
                                rowLabel(
                                    icon: "person.2",
                                    title: "Switch to client",
                                    subtitle: "Browse & book as a client",
                                    working: session.isWorking
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(session.isWorking)
                        }
                    }

                    if let message = session.errorMessage {
                        Text(message)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.ember)
                    }

                    BrandSection(title: "Appearance") {
                        BrandSurface {
                            Picker("Theme", selection: Binding(
                                get: { theme.preference },
                                set: { theme.preference = $0 }
                            )) {
                                ForEach(ThemePreference.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
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
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 120)   // clear the raised footer
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .tint(BrandColor.accent)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            BrandAvatar(name: session.currentUser?.email ?? "Pro", size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Pro studio")
                    .font(BrandFont.display(22, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                if let email = session.currentUser?.email {
                    Text(email)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.top, 4)
    }

    private func rowLabel(icon: String, title: String, subtitle: String, working: Bool) -> some View {
        BrandSurface {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(BrandColor.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(subtitle)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
                Spacer()
                if working {
                    ProgressView().tint(BrandColor.accent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
    }
}
