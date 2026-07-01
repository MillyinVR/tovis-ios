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
        ProPerformanceSectionsView(
            revenue: data.revenue,
            primaryStats: data.primaryStats,
            secondaryStats: data.secondaryStats,
            topServices: data.topServices
        )
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
