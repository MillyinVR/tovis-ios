// Pro data-migration wizard — review / go-live screen. The native counterpart of
// the web `/pro/migrate/review` page (app/pro/migrate/review/page.tsx +
// MigrateReviewClient.tsx + buildReviewViewModel.ts), which is RSC-only. It
// presents the same migration summary the entry screen loads — so it takes a
// `ProMigrationSummary` from the entry screen rather than re-fetching (the entry
// screen owns the load + the build-dark "unavailable" state).
//
// Mirrors web buildReviewViewModel: three tone-coded summary cards (services /
// clients / calendar), the price-grace raise recap, a preflight checklist, and a
// go-live confirmation. On web the imports commit silently per step, so "go live"
// is just the pro's confirmation → back to the dashboard; here it dismisses the
// wizard. Part of increment 1 (the two read-only bookend screens).
import SwiftUI
import TovisKit

struct ProMigrateReviewView: View {
    @Environment(\.dismiss) private var dismiss

    let summary: ProMigrationSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Everything looks good — here’s what’s coming over.")
                    .font(BrandFont.display(22, .medium))
                    .foregroundStyle(BrandColor.textPrimary)

                summaryCards
                if !summary.raises.isEmpty { raiseRecap }
                preflight
                goLive
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 48)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.large)
        .tint(BrandColor.accent)
    }

    // MARK: - Summary cards

    private var summaryCards: some View {
        VStack(spacing: 10) {
            summaryCard(
                icon: "list.bullet.rectangle", tone: BrandColor.gold,
                title: "Service menu", subtitle: "Mapped to the catalog",
                stats: [
                    ("\(summary.offerings)", "services"),
                    ("\(summary.raises.count)", "raises"),
                ]
            )
            summaryCard(
                icon: "person.2.fill", tone: BrandColor.accent,
                title: "Clients", subtitle: "Imported to your roster",
                stats: [("\(summary.clients)", "with upcoming bookings")]
            )
            summaryCard(
                icon: "calendar", tone: BrandColor.iris,
                title: "Calendar", subtitle: "Bookings + held time",
                stats: [
                    ("\(summary.importedBookings)", "bookings"),
                    ("\(summary.importedBlocks)", "blocked"),
                ]
            )
        }
    }

    private func summaryCard(
        icon: String, tone: Color, title: String, subtitle: String,
        stats: [(String, String)]
    ) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 18)).foregroundStyle(tone)
                    Spacer()
                    Text("Complete")
                        .font(BrandFont.mono(11))
                        .foregroundStyle(BrandColor.emerald)
                        .padding(.vertical, 4).padding(.horizontal, 10)
                        .background(BrandColor.emerald.opacity(0.14))
                        .clipShape(Capsule())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(subtitle)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
                HStack(spacing: 20) {
                    ForEach(stats, id: \.1) { stat in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stat.0)
                                .font(BrandFont.body(18, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                            Text(stat.1)
                                .font(BrandFont.body(11))
                                .foregroundStyle(BrandColor.textMuted)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Raise plan recap

    private var raiseRecap: some View {
        BrandSection(title: "Your raise plan 🎉") {
            BrandSurface {
                VStack(spacing: 0) {
                    ForEach(Array(summary.raises.enumerated()), id: \.offset) { index, raise in
                        if index > 0 {
                            Divider().overlay(BrandColor.textMuted.opacity(0.12))
                        }
                        HStack {
                            Text(raise.serviceName)
                                .font(BrandFont.body(14))
                                .foregroundStyle(BrandColor.textPrimary)
                            Spacer()
                            Text("\(raise.fromLabel) → \(raise.toLabel)")
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textMuted)
                            Text(raise.cadenceLabel)
                                .font(BrandFont.mono(10))
                                .foregroundStyle(BrandColor.textMuted)
                        }
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    // MARK: - Preflight checklist

    private var preflight: some View {
        BrandSection(title: "Preflight") {
            VStack(spacing: 8) {
                checklistRow("Service menu reviewed", done: summary.offerings > 0)
                checklistRow("Clients imported", done: summary.clients > 0)
                checklistRow("Calendar transferred", done: summary.calendarCount > 0)
                checklistRow("No notifications sent to clients", done: true)
            }
        }
    }

    private func checklistRow(_ label: String, done: Bool) -> some View {
        BrandSurface {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(done ? BrandColor.emerald : BrandColor.textMuted)
                Text(label)
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textSecondary)
                Spacer()
            }
        }
    }

    // MARK: - Go live

    private var goLive: some View {
        VStack(spacing: 12) {
            Text("Ready to go live")
                .font(BrandFont.display(18, .medium))
                .foregroundStyle(BrandColor.textPrimary)
            Button { dismiss() } label: {
                Text("Go live")
                    .font(BrandFont.body(16, .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .foregroundStyle(BrandColor.onAccent)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                trustPill("Nothing sent to clients yet")
                trustPill("Reversible until you go live")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20).padding(.horizontal, 16)
        .background(BrandColor.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.top, 4)
    }

    private func trustPill(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.mono(10))
            .foregroundStyle(BrandColor.textMuted)
            .padding(.vertical, 5).padding(.horizontal, 10)
            .background(BrandColor.textMuted.opacity(0.1))
            .clipShape(Capsule())
    }
}
