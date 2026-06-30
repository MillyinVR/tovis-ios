// Pro Last Minute — the native counterpart of the web `/pro/last-minute`, backed
// by GET /api/v1/pro/last-minute/workspace (tovis-app PR #439). A read summary of
// the last-minute configuration: master state, priority offer, discount tiers,
// per-day availability, per-service rules and blocked dates. Lives on the
// Overview home's Last Minute tab.
//
// Read-focused v1: the web editor (toggles + tier/price/rule/block PATCH) is a
// follow-up — the settings/rules/blocks write endpoints already exist.
import SwiftUI
import TovisKit

struct ProLastMinuteView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded(ProLastMinuteWorkspace)
        case failed(String)
    }

    @State private var phase: Phase = .loading

    private static let dayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 50)
                case let .failed(message):
                    errorState(message)
                case let .loaded(workspace):
                    content(workspace)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 120)   // clear the raised footer
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
        .onChange(of: session.refreshTick) { Task { await load() } }
    }

    @ViewBuilder
    private func content(_ workspace: ProLastMinuteWorkspace) -> some View {
        let s = workspace.settings

        statusCard(s)

        BrandSection(title: "Discount tiers") {
            BrandSurface(tint: BrandColor.bgSecondary) {
                VStack(alignment: .leading, spacing: 8) {
                    row("Priority offer", s.priorityOfferEnabled ? "On · \(s.priorityOfferMinutes) min" : "Off")
                    row("Night-before window", "\(s.tier2NightBeforeMinutes) min")
                    row("Day-of window", "\(s.tier3DayOfMinutes) min")
                    if let min = Wire.money(s.minCollectedSubtotal) {
                        row("Min collected subtotal", min)
                    }
                    row("Visibility", s.defaultVisibilityMode.replacingOccurrences(of: "_", with: " ").capitalized)
                }
            }
        }

        BrandSection(title: "Available days") {
            availabilityRow(s)
        }

        if !workspace.offerings.isEmpty {
            BrandSection(title: "Service rules") {
                VStack(spacing: 10) {
                    ForEach(workspace.offerings) { offering in
                        serviceRuleCard(offering, rule: workspace.settings.serviceRules.first { $0.serviceId == offering.serviceId })
                    }
                }
            }
        }

        if !s.blocks.isEmpty {
            BrandSection(title: "Blocked dates") {
                VStack(spacing: 10) {
                    ForEach(s.blocks) { block in
                        BrandSurface(tint: BrandColor.bgSecondary) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(Wire.dateTime(block.startAt, timeZone: workspace.timeZone)) → \(Wire.dateTime(block.endAt, timeZone: workspace.timeZone))")
                                    .font(BrandFont.body(13, .semibold))
                                    .foregroundStyle(BrandColor.textPrimary)
                                if let reason = block.reason, !reason.isEmpty {
                                    Text(reason)
                                        .font(BrandFont.body(12))
                                        .foregroundStyle(BrandColor.textMuted)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func statusCard(_ s: ProLastMinuteWorkspace.Settings) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            HStack(spacing: 12) {
                Circle()
                    .fill(s.enabled ? BrandColor.emerald : BrandColor.textMuted.opacity(0.4))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last-minute openings")
                        .font(BrandFont.body(15, .bold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(s.enabled ? "On — eligible openings are offered automatically." : "Off")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                Spacer()
                BrandPill(text: s.enabled ? "ON" : "OFF", tint: s.enabled ? BrandColor.emerald : BrandColor.textMuted)
            }
        }
    }

    private func availabilityRow(_ s: ProLastMinuteWorkspace.Settings) -> some View {
        let disabled = [s.disableMon, s.disableTue, s.disableWed, s.disableThu, s.disableFri, s.disableSat, s.disableSun]
        return HStack(spacing: 6) {
            ForEach(Array(Self.dayLabels.enumerated()), id: \.offset) { idx, label in
                let on = !disabled[idx]
                Text(label.uppercased())
                    .font(BrandFont.mono(9))
                    .foregroundStyle(on ? BrandColor.onAccent : BrandColor.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(on ? BrandColor.accent : BrandColor.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func serviceRuleCard(_ offering: ProLastMinuteWorkspace.Offering, rule: ProLastMinuteWorkspace.ServiceRule?) -> some View {
        let enabled = rule?.enabled ?? false
        return BrandSurface(tint: BrandColor.bgSecondary) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(offering.name)
                        .font(BrandFont.body(14, .bold))
                        .foregroundStyle(BrandColor.textPrimary)
                    if let min = Wire.money(rule?.minCollectedSubtotal) {
                        Text("Min subtotal \(min)")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    } else if let base = Wire.money(offering.basePrice) {
                        Text("Base \(base)")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }
                Spacer()
                BrandPill(text: enabled ? "Eligible" : "Off", tint: enabled ? BrandColor.emerald : BrandColor.textMuted)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
            Spacer()
            Text(value)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    private func load() async {
        do {
            let workspace = try await session.client.proSchedule.lastMinuteWorkspace()
            phase = .loaded(workspace)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your last-minute settings.")
        }
    }
}
