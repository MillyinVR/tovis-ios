// Pro Overview — the native counterpart of the web `/pro/dashboard`
// (ProOverviewDashboard), backed by GET /api/v1/pro/overview (tovis-app PR #437).
// Month nav + revenue hero + primary/secondary stat cards + top services. The
// default tab on the Overview home. All values arrive pre-formatted from the
// server, so this stays presentation-only.
import SwiftUI
import TovisKit

struct ProOverviewView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded(ProOverviewResponse)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var month: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 50)
                case let .failed(message):
                    errorState(message)
                case let .loaded(data):
                    content(data)
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
    private func content(_ data: ProOverviewResponse) -> some View {
        monthNav(data.months)
        revenueCard(data.revenue)
        statGrid(data.primaryStats)
        if !data.secondaryStats.isEmpty {
            statGrid(data.secondaryStats)
        }
        topServices(data.topServices)
    }

    private func monthNav(_ months: [ProOverviewResponse.MonthNav]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(months) { m in
                    Button {
                        month = m.key
                        Task { await load() }
                    } label: {
                        Text(m.label)
                            .font(BrandFont.body(12, .bold))
                            .foregroundStyle(m.active ? BrandColor.onAccent : BrandColor.textPrimary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            .background(m.active ? BrandColor.accent : BrandColor.bgSecondary)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(BrandColor.textMuted.opacity(m.active ? 0 : 0.18), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func revenueCard(_ revenue: ProOverviewResponse.Revenue) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 6) {
                Text("REVENUE")
                    .font(BrandFont.mono(9))
                    .tracking(1.6)
                    .foregroundStyle(BrandColor.textSecondary)
                Text(revenue.value)
                    .font(BrandFont.display(34, .bold))
                    .foregroundStyle(BrandColor.textPrimary)
                HStack(spacing: 8) {
                    Text(revenue.trendLabel)
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(trendTint(revenue.trendTone))
                    Text(revenue.sub)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statGrid(_ metrics: [ProOverviewResponse.Metric]) -> some View {
        HStack(spacing: 10) {
            ForEach(metrics) { metric in
                BrandSurface(tint: BrandColor.bgSecondary) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(metric.value)
                            .font(BrandFont.display(22, .bold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text(metric.label)
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(BrandColor.textSecondary)
                        Text(metric.sub)
                            .font(BrandFont.body(11))
                            .foregroundStyle(BrandColor.textMuted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func topServices(_ services: [ProOverviewResponse.TopService]) -> some View {
        if !services.isEmpty {
            BrandSection(title: "Top services") {
                VStack(spacing: 10) {
                    ForEach(services) { service in
                        BrandSurface(tint: BrandColor.bgSecondary) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(service.name)
                                        .font(BrandFont.body(14, .bold))
                                        .foregroundStyle(BrandColor.textPrimary)
                                    Text("\(service.bookings) booking\(service.bookings == 1 ? "" : "s")")
                                        .font(BrandFont.body(12))
                                        .foregroundStyle(BrandColor.textMuted)
                                }
                                Spacer()
                                Text(service.revenueLabel)
                                    .font(BrandFont.body(14, .semibold))
                                    .foregroundStyle(BrandColor.accent)
                            }
                        }
                    }
                }
            }
        }
    }

    private func trendTint(_ tone: String) -> Color {
        switch tone {
        case "positive": return BrandColor.emerald
        case "negative": return BrandColor.ember
        default: return BrandColor.textMuted
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
            let data = try await session.client.proOverview.overview(month: month)
            phase = .loaded(data)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your overview.")
        }
    }
}
