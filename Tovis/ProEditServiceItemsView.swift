// Edit the services on an existing booking — the native port of the web calendar
// BookingModal's service editor (`PATCH /pro/bookings/{id} { serviceItems }`, via
// `ProBookingService.editServiceItems`). It's a flat, base-swappable list: the
// first row is the BASE, the rest ADD_ONs, and the server re-derives every
// price + duration from the offering (what's shown here is the current snapshot,
// labelled as recalculated on save). Presented as a sheet from the pro booking
// detail while the booking is non-terminal; this is the first native surface that
// changes the services on an existing booking (predecessor for mid-session change).
import SwiftUI
import TovisKit

struct ProEditServiceItemsView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let bookingId: String
    /// The booking's location mode ("SALON" | "MOBILE") — picks the sellable-services
    /// price/duration column.
    let locationType: String
    let initialItems: [ProBookingServiceItem]
    /// Called after a successful save so the host can refresh the booking detail.
    var onSaved: () -> Void

    private enum Phase { case loading, loaded, failed(String) }

    @State private var phase: Phase = .loading
    @State private var catalog: [ProSellableService] = []
    @State private var draft: [DraftServiceItem] = []
    /// The seeded item keys — the "no changes" baseline for the Save gate.
    @State private var baselineKeys: [String] = []
    @State private var notifyClient = false
    @State private var saving = false
    @State private var saveError: String?

    /// A draft row. `price`/`durationMinutes` are display-only — the server
    /// re-derives both from the offering on save.
    private struct DraftServiceItem: Identifiable, Equatable {
        let id = UUID()
        let serviceId: String
        let offeringId: String
        let name: String
        let price: String?
        let durationMinutes: Int?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 80)
                case let .failed(message):
                    failedState(message)
                case .loaded:
                    itemsCard
                    addCard
                    summaryCard
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Edit services")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary).disabled(saving)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await save() } } label: {
                    if saving { ProgressView().tint(BrandColor.accent) } else { Text("Save").fontWeight(.semibold) }
                }
                .tint(BrandColor.accent)
                .disabled(!canSave)
            }
        }
        .task { await load() }
    }

    // MARK: - Current items

    private var itemsCard: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                Text("Services").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                if draft.isEmpty {
                    Text("No services — add at least one below.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(BrandColor.bgPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    ForEach(Array(draft.enumerated()), id: \.element.id) { index, row in
                        itemRow(row, isBase: index == 0)
                    }
                }
            }
        }
    }

    private func itemRow(_ row: DraftServiceItem, isBase: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name).font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    BrandPill(text: isBase ? "BASE" : "ADD-ON", tint: isBase ? BrandColor.accent : BrandColor.textMuted)
                }
                Text(rowDetail(row)).font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
            }
            Spacer()
            Button {
                draft.removeAll { $0.id == row.id }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 20)).foregroundStyle(BrandColor.ember.opacity(0.85))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(row.name)")
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(BrandColor.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func rowDetail(_ row: DraftServiceItem) -> String {
        var parts: [String] = []
        if let price = row.price, let money = Wire.money(price) { parts.append(money) }
        if let mins = row.durationMinutes, mins > 0 { parts.append("\(mins) min") }
        return parts.isEmpty ? "Price set by service" : parts.joined(separator: " · ")
    }

    // MARK: - Add a service

    @ViewBuilder
    private var addCard: some View {
        let options = addableOptions
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add a service").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                if options.isEmpty {
                    Text(catalog.isEmpty ? "No sellable services for this location." : "All your services are already added.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                } else {
                    Menu {
                        ForEach(options) { svc in
                            Button {
                                add(svc)
                            } label: {
                                Text(optionLabel(svc))
                            }
                        }
                    } label: {
                        HStack {
                            Text(draft.isEmpty ? "Choose a base service" : "Add another service")
                                .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
                            Spacer()
                            Image(systemName: "plus.circle.fill").foregroundStyle(BrandColor.accent)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 12)
                        .background(BrandColor.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                Text("The first service is the base; anything after is an add-on.")
                    .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Subtotal").font(BrandFont.body(12.5)).foregroundStyle(BrandColor.textMuted)
                    Spacer()
                    Text(Wire.money(String(format: "%.2f", subtotal)) ?? "—")
                        .font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
                }
                HStack {
                    Text("Duration").font(BrandFont.body(12.5)).foregroundStyle(BrandColor.textMuted)
                    Spacer()
                    Text(totalDuration > 0 ? "\(totalDuration) min" : "—")
                        .font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
                }
                Text("Final price and duration are recalculated when you save.")
                    .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted).padding(.top, 2)

                Divider().overlay(BrandColor.textMuted.opacity(0.15)).padding(.vertical, 2)

                Toggle(isOn: $notifyClient) {
                    Text("Notify the client of this change")
                        .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                }
                .tint(BrandColor.accent)

                if let saveError {
                    Text(saveError).font(BrandFont.body(12)).foregroundStyle(BrandColor.ember)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary).multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 70)
    }

    // MARK: - Derived

    /// Sellable services not already in the draft (matched by offering).
    private var addableOptions: [ProSellableService] {
        let taken = Set(draft.map(\.offeringId))
        return catalog.filter { !taken.contains($0.offeringId) }
    }

    private func optionLabel(_ svc: ProSellableService) -> String {
        var parts = [svc.name]
        if let price = svc.selectedMode?.priceStartingAt, let money = Wire.money(price) { parts.append(money) }
        if let mins = svc.selectedMode?.durationMinutes, mins > 0 { parts.append("\(mins) min") }
        return parts.joined(separator: " · ")
    }

    private var subtotal: Double {
        draft.reduce(0) { $0 + (Double($1.price ?? "") ?? 0) }
    }

    private var totalDuration: Int {
        draft.reduce(0) { $0 + ($1.durationMinutes ?? 0) }
    }

    private var draftKeys: [String] { draft.map { "\($0.serviceId)|\($0.offeringId)" } }

    /// Save is offered once the draft is a valid, changed, non-empty set. Every
    /// row already carries an offeringId (both seed + add require one), so the only
    /// gates are: non-empty, actually changed, and not mid-save.
    private var canSave: Bool {
        !saving && !draft.isEmpty && draftKeys != baselineKeys
    }

    // MARK: - Actions

    private func add(_ svc: ProSellableService) {
        guard !draft.contains(where: { $0.offeringId == svc.offeringId }) else { return }
        draft.append(DraftServiceItem(
            serviceId: svc.serviceId,
            offeringId: svc.offeringId,
            name: svc.name,
            price: svc.selectedMode?.priceStartingAt,
            durationMinutes: svc.selectedMode?.durationMinutes
        ))
    }

    private func load() async {
        // Seed the draft from the booking's current items (base first), keeping only
        // items with an offeringId — the PATCH needs one per item, and real booking
        // items always carry it.
        let seeded = initialItems
            .sorted { a, b in
                if a.isAddOn != b.isAddOn { return !a.isAddOn }   // base(s) first
                return a.sortOrder < b.sortOrder
            }
            .compactMap { item -> DraftServiceItem? in
                guard let offeringId = item.offeringId else { return nil }
                return DraftServiceItem(
                    serviceId: item.serviceId,
                    offeringId: offeringId,
                    name: item.serviceName,
                    price: item.priceSnapshot,
                    durationMinutes: item.durationMinutesSnapshot
                )
            }
        draft = seeded
        baselineKeys = seeded.map { "\($0.serviceId)|\($0.offeringId)" }

        do {
            catalog = try await session.client.proBookings.sellableServices(locationType: locationType)
            phase = .loaded
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your services. Try again.")
        }
    }

    private func save() async {
        guard canSave else { return }
        saving = true; saveError = nil
        defer { saving = false }
        let items = draft.enumerated().map { index, row in
            ProBookingServiceItemInput(serviceId: row.serviceId, offeringId: row.offeringId, sortOrder: index)
        }
        do {
            try await session.client.proBookings.editServiceItems(
                bookingId: bookingId, items: items, notifyClient: notifyClient)
            onSaved()
            dismiss()
        } catch let error as APIError {
            saveError = error.userMessage
        } catch {
            saveError = "Couldn’t update the services. Try again."
        }
    }
}
