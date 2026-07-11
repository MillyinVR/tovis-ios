// Native manage screen for the client's saved mobile service addresses — the
// "Mobile service addresses" half of the web Settings → Addresses card
// (app/client/(gated)/settings/ClientAddressesSettings.tsx), backed by
// GET/POST/PATCH/DELETE /api/v1/client/addresses[/id] via AddressesService.
//
// A SERVICE_ADDRESS is where an at-home (MOBILE) booking is performed; it carries a
// geocoded lat/lng so the pro's travel-radius check can run. This screen lists them,
// makes one the default, edits label/apt (and optionally re-picks the address), and
// deletes. Adding reuses the existing AddServiceAddressSheet (autocomplete-first).
//
// Search areas (the discovery-origin kind) are intentionally out of scope here —
// they belong to the separate discovery-location settings slice.
import SwiftUI
import TovisKit

struct ClientServiceAddressesView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.openURL) private var openURL

    private enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var addresses: [ClientAddress] = []

    @State private var showAdd = false
    @State private var editing: ClientAddress?
    @State private var deleteTarget: ClientAddress?

    /// The id of a row whose Make-default / Delete is in flight (for its spinner).
    @State private var busyId: String?
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
        .navigationTitle("Saved addresses")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .sheet(isPresented: $showAdd) {
            AddServiceAddressSheet { _ in Task { await load() } }
        }
        .sheet(item: $editing) { address in
            EditServiceAddressSheet(address: address) { Task { await load() } }
        }
        .confirmationDialog(
            "Delete this address?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { target in
            Button("Delete", role: .destructive) { Task { await remove(target) } }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { target in
            Text(target.displayLine)
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

                if addresses.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 12) {
                        ForEach(addresses) { addressCard($0) }
                    }
                }

                Button { showAdd = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add address").font(BrandFont.body(16, .semibold))
                    }
                    .foregroundStyle(BrandColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Service addresses")
                .font(BrandFont.display(18, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("Where your pros come to you. Required for at-home bookings — salon-only browsing doesn’t need one.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    private var emptyState: some View {
        Text("No saved service addresses yet.")
            .font(BrandFont.body(14, .medium))
            .foregroundStyle(BrandColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func addressCard(_ address: ClientAddress) -> some View {
        let busy = busyId == address.id
        return BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(address.displayLine)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(2)
                    if address.isDefault { defaultBadge }
                    Spacer(minLength: 0)
                    if busy { ProgressView().controlSize(.mini).tint(BrandColor.accent) }
                }

                if let detail = address.detailLine {
                    Text(detail)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if !address.isDefault {
                        pill("Make default", icon: "star") { Task { await makeDefault(address) } }
                    }
                    pill("Edit", icon: "pencil") { editing = address }
                    if address.mapsURL != nil {
                        pill("Maps", icon: "map") { if let url = address.mapsURL { openURL(url) } }
                    }
                    Spacer(minLength: 0)
                    pill("Delete", icon: "trash", danger: true) { deleteTarget = address }
                }
                .disabled(busy)
            }
        }
    }

    private var defaultBadge: some View {
        Text("Default")
            .font(BrandFont.body(10, .semibold))
            .foregroundStyle(BrandColor.accent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(BrandColor.accent.opacity(0.12), in: Capsule())
    }

    private func pill(
        _ title: String,
        icon: String,
        danger: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let tint = danger ? BrandColor.ember : BrandColor.textSecondary
        return Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(BrandFont.body(12, .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .overlay(Capsule().stroke(tint.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
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
        do {
            addresses = try await session.client.addresses.serviceAddresses()
            phase = .loaded
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your saved addresses.")
        }
    }

    private func makeDefault(_ address: ClientAddress) async {
        guard busyId == nil else { return }
        busyId = address.id
        banner = nil
        defer { busyId = nil }
        do {
            _ = try await session.client.addresses.setDefault(id: address.id)
            await reloadKeepingPhase()
        } catch let error as APIError {
            banner = error.userMessage
        } catch {
            banner = "Couldn’t update your default address."
        }
    }

    private func remove(_ address: ClientAddress) async {
        guard busyId == nil else { return }
        busyId = address.id
        banner = nil
        deleteTarget = nil
        defer { busyId = nil }
        do {
            try await session.client.addresses.delete(id: address.id)
            await reloadKeepingPhase()
        } catch let error as APIError {
            banner = error.userMessage
        } catch {
            banner = "Couldn’t delete that address."
        }
    }

    /// Reload the list without flashing the full-screen spinner (a row action already
    /// showed its own inline spinner).
    private func reloadKeepingPhase() async {
        do {
            addresses = try await session.client.addresses.serviceAddresses()
            phase = .loaded
        } catch let error as APIError {
            banner = error.userMessage
        } catch {
            banner = "Couldn’t refresh your saved addresses."
        }
    }
}

/// Edit a saved SERVICE_ADDRESS: rename its label, change the apt/unit, promote it to
/// default, and optionally re-pick the underlying address via autocomplete. Mirrors
/// the web edit form; re-picking is optional (a label/apt-only save keeps the existing
/// geocoded address, so the server never re-verifies it).
struct EditServiceAddressSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let address: ClientAddress
    let onSaved: () -> Void

    @State private var label: String
    @State private var apt: String
    @State private var makeDefault: Bool

    @State private var changingAddress = false
    @State private var picked: PlaceDetails?

    @State private var saving = false
    @State private var error: String?

    init(address: ClientAddress, onSaved: @escaping () -> Void) {
        self.address = address
        self.onSaved = onSaved
        _label = State(initialValue: address.label ?? "")
        _apt = State(initialValue: address.addressLine2 ?? "")
        _makeDefault = State(initialValue: address.isDefault)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field("Label (optional)", text: $label, placeholder: "Home, Studio…")

                    addressSection

                    if address.isDefault {
                        Text("This is your default service address.")
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                    } else {
                        Toggle(isOn: $makeDefault) {
                            Text("Make this my default")
                                .font(BrandFont.body(15, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                        }
                        .tint(BrandColor.accent)
                    }

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }

                    SignupPrimaryButton(
                        title: "Save",
                        isLoading: saving
                    ) {
                        Task { await save() }
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Edit address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
            }
        }
        .tint(BrandColor.accent)
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignupFieldLabel("Address")

            // The current (saved) address, shown until the client chooses to re-pick.
            VStack(alignment: .leading, spacing: 4) {
                Text(picked?.formattedAddress ?? address.displayLine)
                    .font(BrandFont.body(15, .medium))
                    .foregroundStyle(BrandColor.textPrimary)
                if picked != nil {
                    Text("New address selected")
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))

            if changingAddress {
                PlacesAddressSearchField(picked: $picked, disabled: saving)
            } else {
                Button { changingAddress = true } label: {
                    Text("Change address")
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.accent)
                }
                .buttonStyle(.plain)
            }

            if picked != nil {
                field("Apt / suite (optional)", text: $apt, placeholder: "Apt 4B")
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SignupFieldLabel(title)
            TextField(placeholder, text: text)
                .font(BrandFont.body(15)).foregroundStyle(BrandColor.textPrimary)
                .padding(12)
                .background(BrandColor.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedApt = apt.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            _ = try await session.client.addresses.updateServiceAddress(
                id: address.id,
                label: trimmedLabel.isEmpty ? nil : trimmedLabel,
                apt: trimmedApt.isEmpty ? nil : trimmedApt,
                isDefault: address.isDefault ? true : makeDefault,
                place: picked
            )
            onSaved()
            dismiss()
        } catch let apiError as APIError {
            error = apiError.userMessage
        } catch {
            self.error = "Couldn’t save that address. Try again."
        }
    }
}
