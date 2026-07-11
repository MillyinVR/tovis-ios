// The client Settings hub — the native home for the web
// app/client/(gated)/settings surface. Mirrors the pro-side pattern
// (ProProfileTabView.accountSection): grouped BrandSection blocks of tappable
// rows that push each sub-screen, plus Appearance + Sign out. Reached from the
// gear in the Me tab header.
//
// Wires the ready sub-areas: Edit profile, Better matches (the personalization
// self-profile), Public profile (handle/bio/public toggle), Saved addresses,
// Discovery location (where "pros near you" searches from), Payment methods (saved
// cards for no-show fees), and Notifications (the existing
// NotificationPreferencesView).
import SwiftUI
import TovisKit

struct ClientSettingsHubView: View {
    @Environment(SessionModel.self) private var session
    @Environment(ThemeStore.self) private var theme

    /// The signed-in email, passed from the Me tab (which already has it) so the
    /// hub can show it without a second fetch.
    var email: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let email {
                    Text(email)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(BrandColor.bgSurface)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))
                }

                BrandSection(title: "Account") {
                    VStack(spacing: 10) {
                        SettingsLinkRow(
                            icon: "person.crop.circle",
                            title: "Edit profile",
                            subtitle: "Name, phone, birthday & avatar"
                        ) { ClientProfileEditView() }

                        SettingsLinkRow(
                            icon: "sparkles",
                            title: "Better matches",
                            subtitle: "Hair, skin & what you’re into"
                        ) { ClientPersonalizationView() }

                        SettingsLinkRow(
                            icon: "at",
                            title: "Public profile",
                            subtitle: "Handle, bio & public looks"
                        ) { ClientPublicProfileEditView() }

                        SettingsLinkRow(
                            icon: "mappin.and.ellipse",
                            title: "Saved addresses",
                            subtitle: "Addresses for at-home service"
                        ) { ClientServiceAddressesView() }

                        SettingsLinkRow(
                            icon: "location.magnifyingglass",
                            title: "Discovery location",
                            subtitle: "Where you search for pros"
                        ) { ClientDiscoveryLocationView() }

                        SettingsLinkRow(
                            icon: "creditcard",
                            title: "Payment methods",
                            subtitle: "Saved cards for no-show fees"
                        ) { PaymentMethodsView() }

                        SettingsLinkRow(
                            icon: "bell.badge",
                            title: "Notifications",
                            subtitle: "Channels & quiet hours"
                        ) { NotificationPreferencesView() }
                    }
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
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .tint(BrandColor.accent)
    }
}

/// A tappable settings row that pushes a destination — the client-hub counterpart
/// of the pro `businessLink`, with an optional subtitle. Kept standalone so later
/// increments (and eventually the pro side) can share one row style.
struct SettingsLinkRow<Destination: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
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
                        if let subtitle {
                            Text(subtitle)
                                .font(BrandFont.body(12))
                                .foregroundStyle(BrandColor.textMuted)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
