// Pro Locations — the native counterpart of the web `/pro/locations`
// (app/pro/locations/LocationsClient.tsx). v1 is the read-only list: each of the
// pro's salon / suite / mobile-base locations with its primary + bookable state,
// address and time zone (`GET /api/v1/pro/locations`, reused via
// `ProCalendarService.locations()`).
//
// The web page also creates (Google Place picker / mobile ZIP+radius), sets the
// primary, publishes drafts and deletes — that editor is a follow-up sub-increment
// (it needs a Places picker). Copy is quoted verbatim from the web list.
import SwiftUI
import TovisKit

struct ProLocationsView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded([ProLocationSummary])
        case failed(String)
    }

    @State private var phase: Phase = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 60)
                case let .failed(message):
                    errorState(message)
                case let .loaded(locations):
                    content(locations)
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

    // MARK: - Content

    @ViewBuilder
    private func content(_ locations: [ProLocationSummary]) -> some View {
        let draftCount = locations.filter { !$0.isBookable }.count

        if draftCount > 0 {
            draftBanner(count: draftCount)
        }

        BrandSection(title: "Your locations") {
            if locations.isEmpty {
                Text("No locations yet.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(locations) { location in
                        locationCard(location)
                    }
                }
            }
        }
    }

    private func draftBanner(count: Int) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(count) location\(count == 1 ? "" : "s") not bookable yet")
                    .font(BrandFont.body(13, .bold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text("Clients can’t book a location until it’s published. Publishing checks each location for a timezone, working hours, and (for salons/suites) an address.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(BrandColor.gold.opacity(0.30), lineWidth: 1)
        )
    }

    private func locationCard(_ location: ProLocationSummary) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(displayTitle(location))
                        .font(BrandFont.body(14, .bold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)

                    if location.isPrimary {
                        BrandPill(text: "PRIMARY", tint: BrandColor.accent)
                    }

                    if let type = location.type, !type.isEmpty {
                        Text(type)
                            .font(BrandFont.body(11, .bold))
                            .foregroundStyle(BrandColor.textSecondary)
                    }

                    if !location.isBookable {
                        BrandPill(text: "Not bookable", tint: BrandColor.gold)
                    }

                    Spacer(minLength: 0)
                }

                if let address = location.formattedAddress, !address.isEmpty {
                    Text(address)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.textPrimary.opacity(0.85))
                }

                Text("Time zone: \(location.timeZone ?? "—")")
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
            }
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
        .padding(.top, 60)
    }

    // MARK: - Helpers

    /// web `formatLocationTitle`: name, else a type fallback.
    private func displayTitle(_ location: ProLocationSummary) -> String {
        if let name = location.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        switch location.type {
        case "SALON": return "Salon location"
        case "SUITE": return "Suite location"
        default:      return "Mobile base"
        }
    }

    private func load() async {
        do {
            let locations = try await session.client.proCalendar.locations()
            phase = .loaded(locations)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your locations.")
        }
    }
}
