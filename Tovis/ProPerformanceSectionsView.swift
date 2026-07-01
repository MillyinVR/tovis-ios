// The performance half of the pro Overview (revenue hero + primary/secondary
// stat grids + top services), WITHOUT the month nav. Shared by the standalone
// ProOverviewView and the folded Finance tab's Overview sub-tab (ProFinanceView),
// so the retained stats render identically in both — mirrors the web
// `ProPerformanceSections` extraction. Values reuse the ProOverviewResponse
// nested types (the Finance response reuses them too).
import SwiftUI
import TovisKit

struct ProPerformanceSectionsView: View {
    let revenue: ProOverviewResponse.Revenue
    let primaryStats: [ProOverviewResponse.Metric]
    let secondaryStats: [ProOverviewResponse.Metric]
    let topServices: [ProOverviewResponse.TopService]

    var body: some View {
        revenueCard(revenue)
        statGrid(primaryStats)
        if !secondaryStats.isEmpty {
            statGrid(secondaryStats)
        }
        topServicesSection(topServices)
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
                        .foregroundStyle(Self.trendTint(revenue.trendTone))
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
    private func topServicesSection(_ services: [ProOverviewResponse.TopService]) -> some View {
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

    static func trendTint(_ tone: String) -> Color {
        switch tone {
        case "positive": return BrandColor.emerald
        case "negative": return BrandColor.ember
        default: return BrandColor.textMuted
        }
    }
}
