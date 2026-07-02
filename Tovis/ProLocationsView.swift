// Pro Locations — the native counterpart of the web `/pro/locations`
// (app/pro/locations/LocationsClient.tsx). Full parity: list the pro's salon /
// suite / mobile-base locations, add new ones (Google place or mobile ZIP+radius),
// publish drafts, tap a location to edit (rename, set primary, lead time, mobile
// base ZIP+radius) and remove it. Add/edit/remove live in `ProLocationSheets.swift`;
// list + publish are wired here via `ProLocationsService`. Copy tracks the web list.
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
    @State private var showAdd = false
    @State private var editing: ProLocationSummary?
    @State private var publishing = false
    @State private var actionError: String?

    private var loadedLocations: [ProLocationSummary] {
        if case let .loaded(locations) = phase { return locations }
        return []
    }

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
        .sheet(isPresented: $showAdd) {
            ProAddLocationSheet(hasExistingLocations: !loadedLocations.isEmpty) {
                Task { await load() }
            }
        }
        .sheet(item: $editing) { location in
            ProLocationEditSheet(location: location) { Task { await load() } }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ locations: [ProLocationSummary]) -> some View {
        addLocationCard

        let draftCount = locations.filter { !$0.isBookable }.count
        if draftCount > 0 { draftBanner(count: draftCount) }

        if let actionError { errorBanner(actionError) }

        BrandSection(title: "Your locations") {
            if locations.isEmpty {
                Text("No locations yet. Add your first so clients can book you.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(locations) { location in
                        Button { editing = location } label: { locationCard(location) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var addLocationCard: some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a location")
                        .font(BrandFont.body(14, .bold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("Powers “near me” discovery and sets the timezone used for booking.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                Spacer(minLength: 0)
                Button { showAdd = true } label: {
                    Text("+ Add")
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.onAccent)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(BrandColor.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func draftBanner(count: Int) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(count) location\(count == 1 ? "" : "s") not bookable yet")
                    .font(BrandFont.body(13, .bold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text("Clients can’t book a location until it’s published. Publishing checks each location for a timezone, working hours, and (for salons/suites) an address.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
                Button { Task { await publish() } } label: {
                    Text(publishing ? "Publishing…" : "Publish now")
                        .font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(publishing ? BrandColor.accent.opacity(0.5) : BrandColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(publishing)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(BrandColor.gold.opacity(0.30), lineWidth: 1)
        )
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(BrandFont.body(13))
            .foregroundStyle(BrandColor.ember)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BrandColor.textMuted)
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
            let locations = try await session.client.proLocations.list()
            phase = .loaded(locations)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your locations.")
        }
    }

    private func publish() async {
        publishing = true
        actionError = nil
        defer { publishing = false }
        do {
            try await session.client.proLocations.publish()
            await load()
        } catch let apiError as APIError {
            actionError = apiError.userMessage
        } catch {
            actionError = "Couldn’t publish your locations. Try again."
        }
    }
}
