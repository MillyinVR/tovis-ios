// Pro data-migration wizard — entry / landing screen. The native counterpart of
// the web `/pro/migrate` entry page (app/pro/migrate/page.tsx +
// MigrateEntryClient.tsx), which is RSC-only (queries Prisma directly via
// loadMigrationReviewSummary), so there is a dedicated native read API:
// GET /api/v1/pro/migrate/summary. Reached from the Profile tab → Business.
//
// Increment 1 covered the two read-only "bookend" screens — this entry progress
// + the review/go-live summary (ProMigrateReviewView). Increment 2 adds the
// clients import step (ProMigrateClientsView), reached from the footer CTA. The
// services + calendar CSV/ICS steps are later increments.
//
// Dark unless ENABLE_PRO_MIGRATION: the summary route 404s while the flag is off,
// so we show a "not available yet" state (same build-dark pattern as
// ProNoShowSettings). No real pro sees this until Tori flips the flag.
import SwiftUI
import TovisKit

struct ProMigrateView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded(ProMigrationSummary)
        case unavailable
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var sourceApp: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 80)
                case .unavailable:
                    unavailableState
                case let .failed(message):
                    failedState(message)
                case let .loaded(summary):
                    loaded(summary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 60)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Import")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
        .tint(BrandColor.accent)
    }

    // MARK: - Loaded

    @ViewBuilder
    private func loaded(_ summary: ProMigrationSummary) -> some View {
        hero
        sourcePicker
        if let sourceApp {
            exportGuideCard(sourceApp)
        }
        bringOver(summary)
        footer(summary)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("◆ Bring your business over")
                .font(BrandFont.mono(11)).tracking(0.6)
                .foregroundStyle(BrandColor.accent)
            Text("Move your clients, service menu, and calendar in one guided pass.")
                .font(BrandFont.display(24, .medium))
                .foregroundStyle(BrandColor.textPrimary)
            Text("You review everything before anything goes live — nothing is sent to your clients.")
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    // MARK: - Source-app picker

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHERE ARE YOU COMING FROM?")
                .font(BrandFont.mono(11)).tracking(0.8)
                .foregroundStyle(BrandColor.textMuted)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(migrationSourceApps, id: \.self) { app in
                    sourceButton(app)
                }
            }
        }
    }

    private func sourceButton(_ app: String) -> some View {
        let selected = sourceApp == app
        return Button {
            sourceApp = selected ? nil : app
        } label: {
            HStack {
                Text(app)
                    .font(BrandFont.body(15))
                    .foregroundStyle(selected ? BrandColor.textPrimary : BrandColor.textSecondary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(BrandColor.accent)
                }
            }
            .padding(.vertical, 14).padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? BrandColor.accent.opacity(0.6) : BrandColor.textMuted.opacity(0.12),
                            lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func exportGuideCard(_ app: String) -> some View {
        let guide = migrationExportGuide(for: app)
        return BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text("How to export from \(app)")
                    .font(BrandFont.body(16, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                exportRow("SERVICE MENU", guide.menu)
                exportRow("CLIENTS", guide.clients)
                exportRow("CALENDAR", guide.calendar)
                if guide.calendarFeed {
                    Text("Live calendar sync available — keep bookings updated automatically.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.accent)
                        .padding(.top, 2)
                }
                Text("Can’t find an export? Most apps hide it under Settings, Reports, or a ••• menu — or upload a simple CSV with the columns each step shows.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private func exportRow(_ label: String, _ step: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(BrandFont.mono(11)).tracking(0.8)
                .foregroundStyle(BrandColor.textMuted)
            Text(step)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    // MARK: - "What you'll bring over"

    private func bringOver(_ summary: ProMigrationSummary) -> some View {
        BrandSection(title: "What you'll bring over") {
            VStack(spacing: 10) {
                progressCard(
                    icon: "list.bullet.rectangle", title: "Service menu",
                    desc: "Mapped to the catalog so names stay clean.",
                    count: summary.servicesCount
                )
                progressCard(
                    icon: "person.2.fill", title: "Clients",
                    desc: "Your contacts, matched and de-duplicated.",
                    count: summary.clientsCount
                )
                progressCard(
                    icon: "calendar", title: "Calendar",
                    desc: "Upcoming bookings and your working hours.",
                    count: summary.calendarCount
                )
            }
        }
    }

    private func progressCard(icon: String, title: String, desc: String, count: Int) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 17))
                        .foregroundStyle(BrandColor.accent)
                        .frame(width: 26)
                    Text(title)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                    statusChip(count: count)
                }
                Text(desc)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
    }

    private func statusChip(count: Int) -> some View {
        let done = count > 0
        let tint = done ? BrandColor.accent : BrandColor.textMuted
        return Text(done ? "\(count) imported" : "Not started")
            .font(BrandFont.mono(11))
            .foregroundStyle(tint)
            .padding(.vertical, 5).padding(.horizontal, 10)
            .background(tint.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Footer CTAs → clients import + calendar import + review summary

    private func footer(_ summary: ProMigrationSummary) -> some View {
        VStack(spacing: 12) {
            NavigationLink {
                ProMigrateClientsView()
            } label: {
                Text("Import your clients")
                    .font(BrandFont.body(16, .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .foregroundStyle(BrandColor.onAccent)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            NavigationLink {
                ProMigrateCalendarView()
            } label: {
                secondaryCTALabel("Import your calendar")
            }
            .buttonStyle(.plain)
            NavigationLink {
                ProMigrateReviewView(summary: summary)
            } label: {
                secondaryCTALabel("Review your migration")
            }
            .buttonStyle(.plain)
            Text("Bringing your service menu over is coming to the app soon. Everything already imported shows in the review.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }

    private func secondaryCTALabel(_ title: String) -> some View {
        Text(title)
            .font(BrandFont.body(16, .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .foregroundStyle(BrandColor.textPrimary)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1)
            )
    }

    // MARK: - Dark / error states

    private var unavailableState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 26)).foregroundStyle(BrandColor.textMuted)
            Text("Coming soon")
                .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
            Text("Bringing your business over from another app isn’t switched on for your account yet.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 70).padding(.horizontal, 20)
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    // MARK: - Load

    private func load() async {
        do {
            let summary = try await session.client.proMigration.summary()
            phase = .loaded(summary)
        } catch let e as APIError {
            if case .server(404, _, _) = e { phase = .unavailable }
            else { phase = .failed(e.userMessage) }
        } catch {
            phase = .failed("Couldn’t load your migration. Try again.")
        }
    }
}
