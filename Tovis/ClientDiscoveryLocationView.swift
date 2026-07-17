// The client "Discovery location" settings slice — the native home for the web
// app/client/(gated)/settings location + the "Search areas" list. It sets where
// "pros near you" searches from (the discovery origin) and the search radius.
//
// A client can save MULTIPLE search areas (parity with the web Settings → Addresses
// "Search areas" list): the list surfaces every saved SEARCH_AREA — including ones
// created on web — and the ACTIVE (default) one is what DiscoverView searches from.
// "Use" promotes an area to active (setDefault); adding a new area appends it (and
// makes it active); the trash removes one.
//
// Persistence mirrors web, which splits the value across two layers:
//   • Origin (lat/lng/placeId/label) → a SEARCH_AREA `ClientAddress`, server-persisted
//     via /api/v1/client/addresses. So areas set on web show up here (and vice-versa)
//     — real cross-device parity. Handled by AddressesService.
//   • Radius → localStorage-only on web (`tovis.viewerLocation.v1`); the addresses
//     API/DTO carry the active area's radius. Mirrored here in `UserDefaults` via
//     `DiscoveryRadius`, written through to the active area's server row.
//
// DiscoverView (the pro-finder) reads the active area to seed its initial map + search.
import SwiftUI
import TovisKit

/// The discovery search radius — the localStorage-only half of the web viewer
/// location, kept device-local in `UserDefaults`. Default and bounds match web's
/// `VIEWER_RADIUS_*` constants; the active area's server radius wins when set.
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
    /// Every saved SEARCH_AREA, active (default) first. The active one drives discovery.
    @State private var areas: [ClientAddress] = []
    @State private var radius = DiscoveryRadius.current

    /// The area just picked in the search field — saving it is driven by its change.
    @State private var picked: PlaceDetails?
    /// Bumped after each save to recreate (and clear) the reused search field.
    @State private var pickerResetToken = 0

    @State private var saving = false
    /// The area id of an in-flight per-row action (activate / delete), for its spinner.
    @State private var busyId: String?
    @State private var banner: String?

    /// The area "pros near you" searches from — the default, else the newest saved.
    private var activeArea: ClientAddress? {
        areas.first(where: \.isDefault) ?? areas.first
    }

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

                areasSection
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
            Text("Save the places you search from — “pros near you” opens at your active area. Tap “Use” to switch, or add another below.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    // MARK: - Areas list

    private var areasSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignupFieldLabel(areas.count > 1 ? "Your search areas" : "Current area")
            if areas.isEmpty {
                emptyAreaCard
            } else {
                ForEach(areas) { area in
                    areaRow(area)
                }
            }
        }
    }

    private var emptyAreaCard: some View {
        BrandSurface {
            Text("No area set — “pros near you” asks for your location. Add one below to open here instead (\(radius) mi radius).")
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func areaRow(_ area: ClientAddress) -> some View {
        let isActive = area.id == activeArea?.id
        return BrandSurface {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(area.displayLine)
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                            .lineLimit(1)
                        if isActive { activeBadge }
                    }
                    if isActive {
                        Text("Searching here • \(radius) mi")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                            .lineLimit(1)
                    } else if let detail = area.detailLine {
                        Text(detail)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if !isActive {
                    Button { Task { await activate(area) } } label: {
                        Text("Use")
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(BrandColor.accent)
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .overlay(Capsule().stroke(BrandColor.accent.opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(saving || busyId != nil)
                }

                deleteControl(area)
            }
        }
    }

    private var activeBadge: some View {
        Text("ACTIVE")
            .font(BrandFont.mono(9)).tracking(1.0)
            .foregroundStyle(BrandColor.onAccent)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(BrandColor.accent)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func deleteControl(_ area: ClientAddress) -> some View {
        if busyId == area.id {
            ProgressView().controlSize(.mini).tint(BrandColor.accent)
        } else {
            Button { Task { await deleteArea(area) } } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BrandColor.textMuted)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .disabled(saving || busyId != nil)
            .accessibilityLabel("Remove \(area.displayLine)")
        }
    }

    // MARK: - Radius

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
            DiscoveryRadius.set(miles)   // local cache / no-area fallback
            // When an area is active, persist the radius on its server row so it
            // syncs across devices (best-effort; the local cache already updated).
            if let id = activeArea?.id {
                Task { try? await session.client.addresses.setSearchAreaRadius(id: id, radiusMiles: miles) }
            }
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

    // MARK: - Add an area

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignupFieldLabel(areas.isEmpty ? "Set your area" : "Add an area")
            // AREA-kind autocomplete (city/ZIP), mirroring the web `kind=AREA`. Picking
            // a result saves it immediately (see the onChange above) and makes it active.
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
            areas = try await session.client.addresses.searchAreas()
            adoptActiveRadius()
            phase = .loaded
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your discovery location.")
        }
    }

    /// The active area's server radius (synced across devices) wins; keep the local
    /// UserDefaults cache in step so DiscoverView's fallback agrees. Areas saved
    /// without a radius leave the local value untouched.
    private func adoptActiveRadius() {
        if let serverRadius = activeArea?.radiusMiles {
            radius = serverRadius
            DiscoveryRadius.set(serverRadius)
        }
    }

    private func reloadAreas() async {
        if let refreshed = try? await session.client.addresses.searchAreas() {
            areas = refreshed
            adoptActiveRadius()
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
            // Additive: a fresh area becomes the active default (the server demotes
            // the prior one) but the others are kept — so the list can hold many.
            _ = try await session.client.addresses.saveSearchArea(from: place, radiusMiles: radius)
            await reloadAreas()
        } catch let error as APIError {
            banner = error.userMessage
        } catch {
            banner = "Couldn’t save your discovery area."
        }
    }

    private func activate(_ area: ClientAddress) async {
        guard busyId == nil, !area.isDefault else { return }
        busyId = area.id
        banner = nil
        defer { busyId = nil }
        do {
            _ = try await session.client.addresses.setDefault(id: area.id)
            await reloadAreas()
        } catch let error as APIError {
            banner = error.userMessage
        } catch {
            banner = "Couldn’t switch your active area."
        }
    }

    private func deleteArea(_ area: ClientAddress) async {
        guard busyId == nil else { return }
        busyId = area.id
        banner = nil
        defer { busyId = nil }
        do {
            try await session.client.addresses.delete(id: area.id)
            await reloadAreas()
        } catch let error as APIError {
            banner = error.userMessage
        } catch {
            banner = "Couldn’t remove that area."
        }
    }
}
