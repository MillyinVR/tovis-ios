// The client "Discovery location" settings slice — the native home for the web
// app/client/(gated)/settings/ClientLocationSettings.tsx. It sets where "pros near
// you" searches from (the discovery origin) and the search radius.
//
// Persistence mirrors web, which splits the value across two layers:
//   • Origin (lat/lng/placeId/label) → a default SEARCH_AREA `ClientAddress`,
//     server-persisted via /api/v1/client/addresses. So an area set on web shows up
//     here (and vice-versa) — real cross-device parity. Handled by AddressesService.
//   • Radius → localStorage-only on web (`tovis.viewerLocation.v1`); the addresses
//     API/DTO carry no radius. Mirrored here in `UserDefaults` via `DiscoveryRadius`.
//
// DiscoverView (the pro-finder) reads both to seed its initial map + search.
import SwiftUI
import TovisKit

/// The discovery search radius — the localStorage-only half of the web viewer
/// location, kept device-local in `UserDefaults` (the addresses API has no server
/// home for it). Default and bounds match web's `VIEWER_RADIUS_*` constants.
enum DiscoveryRadius {
    static let key = "tovis.discovery.radiusMiles"
    static let minMiles = 5
    static let maxMiles = 50
    static let defaultMiles = 15
    static let options = [5, 10, 15, 25, 50]

    /// The saved radius, clamped to bounds; the default when nothing is stored yet.
    static var current: Int {
        guard let stored = UserDefaults.standard.object(forKey: key) as? Int else {
            return defaultMiles
        }
        return min(max(stored, minMiles), maxMiles)
    }

    static func set(_ miles: Int) {
        UserDefaults.standard.set(min(max(miles, minMiles), maxMiles), forKey: key)
    }
}

struct ClientDiscoveryLocationView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    @State private var phase: Phase = .loading
    /// The saved discovery origin (a default SEARCH_AREA), or nil if unset.
    @State private var area: ClientAddress?
    @State private var radius = DiscoveryRadius.current

    /// The area just picked in the search field — saving it is driven by its change.
    @State private var picked: PlaceDetails?
    /// Bumped after each save to recreate (and clear) the reused search field.
    @State private var pickerResetToken = 0

    @State private var saving = false
    @State private var clearing = false
    @State private var banner: String?

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView().tint(BrandColor.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                errorState(message)
            case .loaded:
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Discovery location")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .onChange(of: picked?.placeId) { _, newValue in
            if newValue != nil { Task { await saveArea() } }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                intro

                if let banner {
                    Text(banner)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.ember)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(BrandColor.ember.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                currentCard
                radiusSection
                searchSection
            }
            .padding(20)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where you search")
                .font(BrandFont.display(18, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("Set a home area so “pros near you” opens here — instead of asking for your location each time.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    private var currentCard: some View {
        BrandSurface {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Current area")
                        .font(BrandFont.mono(10)).tracking(1.2)
                        .foregroundStyle(BrandColor.textMuted)
                    if let area {
                        Text("\(area.displayLine) • \(radius) mi")
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                            .lineLimit(2)
                    } else {
                        Text("Not set — \(radius) mi radius")
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                }
                Spacer(minLength: 0)
                if clearing {
                    ProgressView().controlSize(.mini).tint(BrandColor.accent)
                } else if area != nil {
                    Button { Task { await clearArea() } } label: {
                        Text("Clear")
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(BrandColor.textSecondary)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .overlay(Capsule().stroke(BrandColor.textMuted.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                }
            }
        }
    }

    private var radiusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignupFieldLabel("Search radius")
            HStack(spacing: 8) {
                ForEach(DiscoveryRadius.options, id: \.self) { miles in
                    radiusChip(miles)
                }
            }
        }
    }

    private func radiusChip(_ miles: Int) -> some View {
        let selected = radius == miles
        return Button {
            radius = miles
            DiscoveryRadius.set(miles)
        } label: {
            Text("\(miles) mi")
                .font(BrandFont.body(14, .medium))
                .foregroundStyle(selected ? BrandColor.onAccent : BrandColor.textPrimary)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(selected ? BrandColor.accent : BrandColor.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(selected ? 0 : 0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignupFieldLabel(area == nil ? "Set your area" : "Change area")
            // AREA-kind autocomplete (city/ZIP), mirroring the web `kind=AREA`. Picking
            // a result saves it immediately (see the onChange above), like the web sheet.
            PlacesAddressSearchField(
                picked: $picked,
                placeholder: "ZIP code or city (e.g. 92101 or San Diego)",
                kind: "AREA",
                disabled: saving
            )
            .id(pickerResetToken)

            if saving {
                Text("Saving…")
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
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 24)
    }

    // MARK: - Actions

    private func load() async {
        phase = .loading
        radius = DiscoveryRadius.current
        do {
            area = try await session.client.addresses.searchArea()
            phase = .loaded
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your discovery location.")
        }
    }

    private func saveArea() async {
        guard let place = picked, !saving else { return }
        saving = true
        banner = nil
        defer {
            saving = false
            picked = nil
            pickerResetToken += 1   // recreate the field empty for the next search
        }
        do {
            area = try await session.client.addresses.saveSearchArea(
                from: place, replacing: area?.id
            )
        } catch let error as APIError {
            banner = error.userMessage
        } catch {
            banner = "Couldn’t save your discovery area."
        }
    }

    private func clearArea() async {
        guard let current = area, !clearing else { return }
        clearing = true
        banner = nil
        defer { clearing = false }
        do {
            try await session.client.addresses.delete(id: current.id)
            area = nil
        } catch let error as APIError {
            banner = error.userMessage
        } catch {
            banner = "Couldn’t clear your discovery area."
        }
    }
}
