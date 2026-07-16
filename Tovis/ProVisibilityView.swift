// Pro "Why you're showing up" — the native port of the web §6.5 transparency
// section on /pro/dashboard. Where ProLooksPerformanceView says WHAT happened
// (views, saves, followers), this says WHY, and what to pull. Read-only.
// Reached from the Profile tab → Growth.
//
// Every decision — which levers exist, their status, their copy, their order —
// belongs to the server (GET /api/v1/pro/visibility, shared with the web page's
// loader). This screen renders generically from status + copy and holds no
// ranking knowledge, so a new lever server-side needs no client release, and
// native can never tell a pro a different story than web does.
import SwiftUI
import TovisKit

struct ProVisibilityView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase { case loading, loaded(ProVisibilityHealth), failed(String) }
    @State private var phase: Phase = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 60)
                case let .failed(message):
                    errorState(message)
                case let .loaded(health):
                    header(health)
                    levers(health.levers)
                    lookBreakdown(health.looks)
                    notMeasured(health.notMeasured)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Your visibility")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .tint(BrandColor.accent)
    }

    // MARK: - Sections

    private func header(_ health: ProVisibilityHealth) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("◆ Discovery")
                .font(BrandFont.mono(11)).tracking(0.6).foregroundStyle(BrandColor.accent)
            Text(health.discoverable
                 ? "What is helping and hurting how often clients see your work."
                 : "You are not appearing in discovery yet. Start here.")
                .font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
        }
    }

    // Server-ranked — biggest lever first. Never re-sorted here.
    private func levers(_ levers: [ProVisibilityHealth.Lever]) -> some View {
        VStack(spacing: 10) {
            ForEach(levers) { lever in
                BrandSurface {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            Text(lever.headline)
                                .font(BrandFont.body(15, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            statusChip(lever.status)
                        }

                        Text(lever.detail)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        // The fix steps read as guidance rather than buttons:
                        // each href points at a WEB pro path, and the native
                        // equivalents live in other tabs. Deep-linking them is
                        // deferred (BACKLOG) — the labels are written to stand
                        // alone, so nothing is lost but a tap.
                        if !lever.actions.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(lever.actions) { action in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 10))
                                            .foregroundStyle(BrandColor.accent)
                                        Text(action.label)
                                            .font(BrandFont.body(13, .semibold))
                                            .foregroundStyle(BrandColor.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func statusChip(_ status: ProVisibilityStatus) -> some View {
        Text(Self.statusLabel(status))
            .font(BrandFont.mono(9)).tracking(0.5)
            .foregroundStyle(Self.statusTone(status))
            .padding(.vertical, 3).padding(.horizontal, 7)
            .background(Self.statusTone(status).opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .stroke(Self.statusTone(status).opacity(0.3), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 999, style: .continuous))
            .fixedSize()
    }

    private func lookBreakdown(_ looks: ProVisibilityHealth.LookCounts) -> some View {
        // Only surface the non-live buckets that actually have something in
        // them — a clean account shouldn't read as a list of zeros.
        var extras: [String] = []
        if looks.pendingReviewCount > 0 { extras.append("\(looks.pendingReviewCount) awaiting review") }
        if looks.rejectedCount > 0 { extras.append("\(looks.rejectedCount) not approved") }
        if looks.draftCount > 0 { extras.append("\(looks.draftCount) in drafts") }

        let base = "\(looks.feedEligibleCount) live \(looks.feedEligibleCount == 1 ? "look" : "looks")"
            + " · \(looks.distinctTagCount) \(looks.distinctTagCount == 1 ? "tag" : "tags")"
            + " · \(looks.distinctServiceCount) \(looks.distinctServiceCount == 1 ? "service" : "services")"
        let line = extras.isEmpty ? base : base + " · " + extras.joined(separator: " · ")

        return Text(line)
            .font(BrandFont.mono(10)).tracking(0.3)
            .foregroundStyle(BrandColor.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func notMeasured(_ items: [String]) -> some View {
        if !items.isEmpty {
            BrandSection(title: "Does not affect where you appear") {
                BrandSurface {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("·").font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                                Text(item)
                                    .font(BrandFont.body(13))
                                    .foregroundStyle(BrandColor.textMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary).multilineTextAlignment(.center)
            Button { Task { phase = .loading; await load() } } label: {
                Text("Try again").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    // MARK: - Helpers

    private static func statusLabel(_ status: ProVisibilityStatus) -> String {
        switch status {
        case .action: return "ACTION NEEDED"
        case .attention: return "OPPORTUNITY"
        case .good: return "HEALTHY"
        case .unknown: return "NOT MEASURED YET"
        }
    }

    private static func statusTone(_ status: ProVisibilityStatus) -> Color {
        switch status {
        case .action: return BrandColor.ember
        case .attention: return BrandColor.amber
        case .good: return BrandColor.emerald
        case .unknown: return BrandColor.accent
        }
    }

    private func load() async {
        do {
            let health = try await session.client.proVisibility.health()
            phase = .loaded(health)
        } catch let e as APIError {
            phase = .failed(e.userMessage)
        } catch {
            phase = .failed("Couldn’t load your visibility.")
        }
    }
}
