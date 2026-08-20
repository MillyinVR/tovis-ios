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

    /// Whether this account may act as a pro (`ClientMeUser.canSwitchToPro`),
    /// passed down the same way as `email`. Gates the Workspace section: without
    /// it a client-only account would see a row that can only 403.
    ///
    /// This is the ONLY route back to the pro shell from the client side — a
    /// dual-role account that switched pro → client previously had no call site
    /// at all and had to reinstall the app.
    var canSwitchToPro: Bool = false

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

                // Mirrors the pro hub, which puts Workspace above Account and
                // renders the shared session error right beneath it.
                if canSwitchToPro {
                    BrandSection(title: "Workspace") {
                        WorkspaceSwitchRow(target: .pro)
                    }

                    if let message = session.errorMessage {
                        Text(message)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.ember)
                    }
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

                        // W5: the client's own side of chart consent. Web has
                        // carried this at /client/settings/chart-sharing since
                        // #838; iOS could be ASKED (the request is a push) with
                        // nowhere to answer, and no way to see or revoke access.
                        SettingsLinkRow(
                            icon: "eye",
                            title: "Who can see your chart",
                            subtitle: "Allergies, formulas & notes your pro keeps"
                        ) { ClientChartAccessView() }

                        SettingsLinkRow(
                            icon: "bell.badge",
                            title: "Notifications",
                            subtitle: "Channels & quiet hours"
                        ) { NotificationPreferencesView() }

                        // App Store guideline 1.2 requires a UGC app to let a
                        // user block abusive users. The block itself is made
                        // from the feed's long press; this row is where it can
                        // be seen and lifted.
                        SettingsLinkRow(
                            icon: "hand.raised",
                            title: "Blocked accounts",
                            subtitle: "People you’ve blocked from seeing you"
                        ) { BlockedAccountsView() }

                        // App Store guideline 5.1.1(v). Same screen the pro
                        // Profile tab uses — the endpoint is role-agnostic, so
                        // there is one deletion surface, not one per workspace.
                        SettingsLinkRow(
                            icon: "trash",
                            title: "Delete account",
                            subtitle: "Close your account & remove your details"
                        ) { DeleteAccountView() }
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

                SettingsSupportSection()

                SettingsLegalSection()

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
        // iPad: pushed from the Me tab's gear, so it gets none of a sheet's
        // free centered-card cap — see `RegularWidthCapped`. No-op on iPhone.
        .cappedWidth(AdaptiveWidth.reading)
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .tint(BrandColor.accent)
    }
}

/// A tappable settings row that pushes a destination — the client-hub counterpart
/// of the pro `businessLink`, with an optional subtitle. Draws its chrome from the
/// shared `SettingsRowLabel`.
struct SettingsLinkRow<Destination: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            SettingsRowLabel(icon: icon, title: title, subtitle: subtitle)
        }
        .buttonStyle(.plain)
    }
}
