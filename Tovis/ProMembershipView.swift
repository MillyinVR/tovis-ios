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
                    if let usage = cameraUsage { cameraUsageSection(usage) }
                    entitlements(m)
                    manageNote
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
                let items = m.planKey == "free" ? Self.proPreviewEntitlements : m.entitlements
                if items.isEmpty {
                    Text("Your current plan covers the essentials — booking, payments, clients, and growth tools.")
                        .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(items, id: \.self) { key in
                        HStack(spacing: 12) {
                            Image(systemName: m.planKey == "free" ? "lock" : "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(m.planKey == "free" ? BrandColor.textMuted : BrandColor.emerald)
                                .frame(width: 22)
                            Text(Self.entitlementLabel(key))
                                .font(BrandFont.body(14))
                                .foregroundStyle(BrandColor.textPrimary)
                            Spacer()
                        }
                    }
                }
            }
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

    private var manageNote: some View {
        Text("Manage or change your plan from the \(brandName) website.")
            .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
            .padding(.top, 4)
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

    private static let proPreviewEntitlements = [
        "tax_export", "custom_handle", "priority_discovery", "discovery_fee_waiver", "advanced_analytics",
    ]

    private static func entitlementLabel(_ key: String) -> String {
        switch key {
        case "custom_handle": return "Custom handle (name.tovis.me)"
        case "tax_export": return "Tax exports (CSV + Schedule C)"
        case "advanced_analytics": return "Advanced analytics"
        case "priority_discovery": return "Priority placement in discovery"
        case "discovery_fee_waiver": return "No platform fee for your new discovery clients"
        case "white_label": return "Salon white-label"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

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
