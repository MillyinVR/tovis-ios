// The shared row vocabulary for the client (`ClientSettingsHubView`) and pro
// (`ProProfileTabView.accountSection`) settings hubs, plus the Support and Legal
// sections both of them render.
import SwiftUI

/// The chrome of a settings row — icon, title, optional subtitle, chevron.
/// Factored out so a row can either push a destination (`SettingsLinkRow`, the
/// pro `businessLink`) or run an action (the Legal rows below) without either
/// side restating the layout.
struct SettingsRowLabel: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
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
}

/// The in-app contact path. Both settings hubs render this, so it is a section
/// rather than a row in each: the client hub's `SettingsLinkRow` and the pro
/// hub's private `businessLink` are different types, and duplicating the row
/// into each is what this file exists to avoid.
///
/// A native push, not a `SafariView` like the Legal rows below — a ticket filed
/// from an in-app browser would be anonymous and unanswerable. See
/// `ContactSupportView` for why.
struct SettingsSupportSection: View {
    var body: some View {
        BrandSection(title: "Support") {
            NavigationLink {
                ContactSupportView()
            } label: {
                SettingsRowLabel(
                    icon: "questionmark.circle",
                    title: "Contact support",
                    subtitle: "Report an issue or ask about your account"
                )
            }
            .buttonStyle(.plain)
        }
    }
}

/// Privacy Policy + Terms, opened in-app via `SafariView`. Both settings hubs
/// render this so the links are reachable after signup — until now they only
/// appeared on the signup consent row, leaving no way back to them.
struct SettingsLegalSection: View {
    @State private var webLink: SettingsWebLink?

    var body: some View {
        BrandSection(title: "Legal") {
            VStack(spacing: 10) {
                row(icon: "hand.raised", title: "Privacy Policy", url: TovisWebLinks.privacy)
                row(icon: "doc.text", title: "Terms of Service", url: TovisWebLinks.terms)
            }
        }
        .sheet(item: $webLink) { link in
            SafariView(url: link.url)
        }
    }

    private func row(icon: String, title: String, url: URL) -> some View {
        Button {
            webLink = SettingsWebLink(url: url)
        } label: {
            SettingsRowLabel(icon: icon, title: title)
        }
        .buttonStyle(.plain)
    }
}

/// A legal page's web destination, wrapped so `.sheet(item:)` can present it.
private struct SettingsWebLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
