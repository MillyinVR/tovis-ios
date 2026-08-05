// Pro membership status — the native display counterpart to the web
// `/pro/membership` page. Shows the pro's effective plan tier + what it unlocks
// + renewal/trial/comp state. Display-only: purchasing is not offered in-app
// (Apple IAP). Reached from the Profile tab → Growth.
import SwiftUI
import TovisKit

struct ProMembershipView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase { case loading, loaded(ProMembership), failed(String) }
    @State private var phase: Phase = .loading
    /// Loaded independently of the plan so a 404 (endpoint not yet deployed) or
    /// any error simply hides the camera-quota panel instead of failing the page.
    @State private var cameraUsage: ProCameraUsage?
    /// The web membership page, opened in SFSafariViewController. Purchasing is
    /// web-only (Apple IAP), and this used to be a dead-end sentence telling the pro
    /// to go find the site themselves — the single highest conversion-per-line item
    /// in membership-value-brief.md §5.3.
    @State private var manageLink: MembershipWebLink?
    private let brandName = "Tovis"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 60)
                case let .failed(message):
                    errorState(message)
                case let .loaded(m):
                    planHero(m)
                    if let note = statusNote(m) { infoRow(note) }
                    commissionPitch()
                    if let usage = cameraUsage { cameraUsageSection(usage) }
                    entitlements(m)
                    studioNote
                    manageOnWeb
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Membership")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .tint(BrandColor.accent)
    }

    // MARK: - Sections

    private func planHero(_ m: ProMembership) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                Text("◆ Your plan")
                    .font(BrandFont.mono(11)).tracking(0.6)
                    .foregroundStyle(BrandColor.accent)
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.planName(m.planKey))
                        .font(BrandFont.display(28, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                    if m.compPlanKey != nil {
                        tag("Comped")
                    } else if let status = m.status {
                        tag(status.capitalized)
                    }
                }
                if let sub = renewalLine(m) {
                    Text(sub).font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                }
            }
        }
    }

    private func entitlements(_ m: ProMembership) -> some View {
        BrandSection(title: m.planKey == "free" ? "Upgrade unlocks" : "What's included") {
            VStack(spacing: 10) {
                let keys = m.planKey == "free"
                    ? ProMembershipCopy.proPreviewEntitlements
                    : m.entitlements
                // Anything without customer-facing copy is dropped, never auto-titled.
                let items = ProMembershipCopy.advertised(keys)
                if items.isEmpty {
                    Text("Your current plan covers the essentials — booking, payments, clients, and growth tools.")
                        .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(items, id: \.key) { item in
                        HStack(spacing: 12) {
                            Image(systemName: m.planKey == "free" ? "lock" : "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(m.planKey == "free" ? BrandColor.textMuted : BrandColor.emerald)
                                .frame(width: 22)
                            Text(item.label)
                                .font(BrandFont.body(14))
                                .foregroundStyle(BrandColor.textPrimary)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    /// The commission pitch (copy + every claim behind it: ProMembershipCopy).
    private func commissionPitch() -> some View {
        BrandSurface {
            Text(ProMembershipCopy.commissionPitchBody(brandName: brandName))
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// AI-camera monthly image allowance (the "X of Y images left" panel). When
    /// metering is off (`enforced == false`) live usage isn't meaningful yet, so
    /// we show the plan allowance only.
    private func cameraUsageSection(_ u: ProCameraUsage) -> some View {
        BrandSection(title: "AI photographer images") {
            VStack(alignment: .leading, spacing: 12) {
                if u.enforced {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(u.remaining)")
                            .font(BrandFont.display(28, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text("of \(u.quota) left this month")
                            .font(BrandFont.body(14)).foregroundStyle(BrandColor.textMuted)
                    }

                    // Usage bar (share of the monthly allowance consumed).
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(BrandColor.bgSecondary)
                            Capsule()
                                .fill(u.remaining == 0 ? BrandColor.gold : BrandColor.accent)
                                .frame(width: max(4, geo.size.width * u.usedFraction))
                        }
                    }
                    .frame(height: 8)

                    Text("\(u.used) of \(u.quota) used")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                } else {
                    Text("Your plan includes \(u.baseQuota) AI photographer images each month.")
                        .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if u.bonus > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "gift.fill")
                            .font(.system(size: 13)).foregroundStyle(BrandColor.emerald)
                        Text("+\(u.bonus) bonus image\(u.bonus == 1 ? "" : "s") added this month")
                            .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                        Spacer()
                    }
                }
            }
        }
    }

    /// Studio is shown, never sold — it is granted after a conversation, and it is
    /// salon-only with a minimum-pro-count gate that does not exist yet.
    private var studioNote: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text(ProMembershipCopy.studioTitle)
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text(ProMembershipCopy.studioBody)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Was a plain `Text` telling the pro to go find the website on their own.
    /// External-link steering to a web purchase is permitted, so this is a real
    /// button — SFSafariViewController, reusing the same wrapper the Stripe
    /// checkout hand-off uses.
    ///
    /// ⚠️ NOT a signed-in hand-off. SFSafariViewController shares cookies with
    /// Safari, not with this app's session, and the backend has no one-time
    /// sign-in-link endpoint. A pro already signed in on Safari lands straight on
    /// the page; anyone else hits /login, which carries `?from=/pro/membership` and
    /// returns them here. Building a real hand-off means new auth surface (a
    /// single-use, short-TTL, user-bound token) — a security decision, not a UI one.
    private var manageOnWeb: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                manageLink = MembershipWebLink(
                    url: session.client.webPageURL("/pro/membership"),
                )
            } label: {
                HStack(spacing: 8) {
                    Text("Manage plan on the web")
                        .font(BrandFont.body(15, .semibold))
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 14))
                }
                .foregroundStyle(BrandColor.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(BrandColor.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            Text("Plans are purchased and managed on the \(brandName) website.")
                .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
        }
        .padding(.top, 4)
        .sheet(item: $manageLink) { link in
            SafariView(url: link.url) { manageLink = nil }
        }
    }

    private func infoRow(_ text: String) -> some View {
        BrandSurface {
            HStack(spacing: 10) {
                Image(systemName: "info.circle").font(.system(size: 15)).foregroundStyle(BrandColor.accent)
                Text(text).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                Spacer()
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.mono(10)).tracking(0.5)
            .foregroundStyle(BrandColor.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(BrandColor.bgSecondary)
            .clipShape(Capsule())
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { phase = .loading; await load() } } label: {
                Text("Try again")
                    .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    // MARK: - Derived copy

    private func renewalLine(_ m: ProMembership) -> String? {
        if let compUntil = m.compUntil, let d = Wire.date(compUntil) {
            return "Comped until \(Wire.dateOnly(compUntil))" + (d < Date() ? " (expired)" : "")
        }
        if let trial = m.trialEndsAt { return "Free trial ends \(Wire.dateOnly(trial))" }
        if let end = m.currentPeriodEnd {
            return (m.cancelAtPeriodEnd ? "Ends " : "Renews ") + Wire.dateOnly(end)
        }
        return m.planKey == "free" ? "No subscription — you're on the free plan." : nil
    }

    private func statusNote(_ m: ProMembership) -> String? {
        guard let status = m.status else { return nil }
        switch status {
        case "past_due", "unpaid": return "Your last payment didn't go through — update billing to keep your plan."
        case "canceled": return "Your subscription is canceled."
        default: return nil
        }
    }

    // MARK: - Static maps

    private static func planName(_ key: String) -> String {
        switch key {
        case "pro": return "Pro"
        case "premium": return "Premium"
        case "studio": return "Studio"
        default: return "Free"
        }
    }

    // Entitlement labels + the commission pitch live in TovisKit
    // (ProMembershipCopy) so CI actually compiles and tests them — nothing here in
    // `Tovis/` is built by the contract job.

    // MARK: - Load

    private func load() async {
        do {
            let m = try await session.client.proMembership.status()
            phase = .loaded(m)
        } catch let e as APIError {
            phase = .failed(e.userMessage)
        } catch {
            phase = .failed("Couldn’t load your membership.")
        }
        // Best-effort — hides the panel if the endpoint isn't deployed yet.
        cameraUsage = try? await session.client.proCamera.usage()
    }
}

/// The membership page's web destination, wrapped so `.sheet(item:)` can present
/// it — same shape as SettingsRows' SettingsWebLink.
private struct MembershipWebLink: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
