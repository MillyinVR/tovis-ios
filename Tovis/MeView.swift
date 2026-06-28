// The "Me" tab — mirrors the web's /client/me dashboard entry point. Keeps the
// account + appointments reachable now that Appointments is no longer its own
// footer tab (web reaches bookings from here and from the home cards, not the
// footer). Full dashboard parity (looks, follows, credits) lands later.
import SwiftUI
import TovisKit

struct MeView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    BrandSection(title: "Your bookings") {
                        NavigationLink {
                            AppointmentsView()
                        } label: {
                            BrandSurface {
                                HStack(spacing: 12) {
                                    Image(systemName: "calendar")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(BrandColor.accent)
                                    Text("Appointments")
                                        .font(BrandFont.body(16, .semibold))
                                        .foregroundStyle(BrandColor.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(BrandColor.textMuted)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    BrandSection(title: "Appearance") {
                        BrandSurface {
                            HStack(spacing: 12) {
                                Image(systemName: "circle.lefthalf.filled")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(BrandColor.accent)
                                Text("Theme")
                                    .font(BrandFont.body(16, .semibold))
                                    .foregroundStyle(BrandColor.textPrimary)
                                Spacer()
                                ThemeToggle()
                            }
                        }
                    }

                    BrandSection(title: "Account") {
                        Button(role: .destructive) {
                            Task { await session.logout() }
                        } label: {
                            BrandSurface {
                                HStack(spacing: 12) {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(BrandColor.ember)
                                    Text("Sign out")
                                        .font(BrandFont.body(16, .semibold))
                                        .foregroundStyle(BrandColor.textPrimary)
                                    Spacer()
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(BrandColor.accent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Me")
                .font(BrandFont.mono(11))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(BrandColor.textMuted)
            Text(session.currentUser?.email ?? "Your account")
                .font(BrandFont.display(28, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.top, 4)
    }
}