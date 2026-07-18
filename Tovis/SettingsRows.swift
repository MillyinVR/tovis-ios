// The shared row vocabulary for the client (`ClientSettingsHubView`) and pro
// (`ProProfileTabView.accountSection`) settings hubs, plus the Support and Legal
// sections both of them render.
import SwiftUI
import TovisKit

/// The chrome of a settings row — icon, title, optional subtitle, trailing
/// accessory. Factored out so a row can either push a destination
/// (`SettingsLinkRow`, the pro `businessLink`) or run an action (the Legal rows
/// and `WorkspaceSwitchRow` below) without either side restating the layout.
struct SettingsRowLabel: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    /// Swaps the chevron for a spinner while the row's action is in flight.
    var isWorking: Bool = false

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
                if isWorking {
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

/// The "switch workspace" row, shared by every shell that offers one.
///
/// Both pro call sites (`ProProfileTabView.accountSection`, the `ProTopBar`
/// account sheet) had hand-copied this button, and the client shell — which had
/// NO switch affordance at all — would have made a third copy. The copy for each
/// destination lives in `WorkspaceSwitchCopy` below so the two directions can't
/// drift the way the follow toggle did.
///
/// The caller decides *whether* to show this: `CLIENT` is always allowed
/// server-side (anyone may act as a client), but `PRO` needs an APPROVED
/// professional profile, so the client shell gates on
/// `ClientMeUser.canSwitchToPro`. An ungated row would 403 with "Workspace not
/// available" for every client-only account.
///
/// Errors are NOT rendered here: each host already renders `session.errorMessage`
/// in its own layout, and doing it here too would double it up.
struct WorkspaceSwitchRow: View {
    @Environment(SessionModel.self) private var session

    /// The workspace to switch INTO.
    let target: Role
    /// Runs immediately after the switch is kicked off — not after it lands.
    /// The pro account sheet uses it to dismiss itself, which is the behaviour
    /// it had before this was extracted.
    var onSwitch: (() -> Void)? = nil

    var body: some View {
        if let copy = WorkspaceSwitchCopy.forTarget(target) {
            Button {
                Task { await session.switchWorkspace(to: target) }
                onSwitch?()
            } label: {
                SettingsRowLabel(
                    icon: copy.icon,
                    title: copy.title,
                    subtitle: copy.subtitle,
                    isWorking: session.isWorking
                )
            }
            .buttonStyle(.plain)
            .disabled(session.isWorking)
        }
    }
}

/// Per-destination copy for `WorkspaceSwitchRow`. `nil` for workspaces the app
/// has no shell for — ADMIN is web-only, and `.unknown` is the forward-compatible
/// fallback `Role` decodes to — so a role we can't host renders nothing rather
/// than a row that would strand the user.
struct WorkspaceSwitchCopy {
    let icon: String
    let title: String
    let subtitle: String

    static func forTarget(_ target: Role) -> WorkspaceSwitchCopy? {
        switch target {
        case .client:
            WorkspaceSwitchCopy(
                icon: "person.2",
                title: "Switch to client",
                subtitle: "Browse & book as a client"
            )
        case .pro:
            WorkspaceSwitchCopy(
                icon: "briefcase",
                title: "Switch to pro",
                subtitle: "Manage your bookings & clients"
            )
        case .admin, .unknown:
            nil
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
