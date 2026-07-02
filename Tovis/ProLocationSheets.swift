// Add / edit a pro location — the native counterpart of the web
// `/pro/locations` `LocationsClient` create + edit + remove flows.
//
// Create goes through the onboarding endpoint (SALON/SUITE resolve a Google
// place; MOBILE_BASE resolves a ZIP + travel radius) and produces a DRAFT the
// pro publishes from the Locations screen. Edit does a sparse PATCH of the
// name / primary / booking lead time, plus the mobile-base ZIP + radius. Remove
// hits DELETE (the server hard-deletes when unreferenced, archives — keeping
// booking history — when bookings still point at it). Errors surface inline.
import SwiftUI
import TovisKit

// MARK: - Shared pieces

/// Labelled field wrapper matching `ProBlockTimeSheet`'s form styling.
private struct LocationField<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(BrandFont.mono(11))
                .tracking(0.8)
                .foregroundStyle(BrandColor.textMuted)
            content()
        }
    }
}

private struct LocationInputBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private extension View {
    func locationInputBackground() -> some View { modifier(LocationInputBackground()) }
}

/// Booking lead-time presets (minutes) — the pro's minimum notice before a slot.
private struct AdvanceNoticeOption: Identifiable, Equatable {
    let minutes: Int
    var id: Int { minutes }
    let label: String
}

private let advanceNoticeOptions: [AdvanceNoticeOption] = [
    .init(minutes: 0, label: "No lead time"),
    .init(minutes: 15, label: "15 minutes"),
    .init(minutes: 30, label: "30 minutes"),
    .init(minutes: 60, label: "1 hour"),
    .init(minutes: 120, label: "2 hours"),
    .init(minutes: 1440, label: "1 day"),
]

private func advanceNoticeLabel(_ minutes: Int) -> String {
    advanceNoticeOptions.first { $0.minutes == minutes }?.label ?? "\(minutes) min"
}

private func advanceNoticeMenu(selection: Binding<Int>) -> some View {
    Menu {
        ForEach(advanceNoticeOptions) { option in
            Button(option.label) { selection.wrappedValue = option.minutes }
        }
    } label: {
        HStack {
            Text(advanceNoticeLabel(selection.wrappedValue))
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textPrimary)
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BrandColor.textMuted)
        }
        .locationInputBackground()
    }
}

// MARK: - Add

struct ProAddLocationSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case salon = "SALON"
        case suite = "SUITE"
        case mobile = "MOBILE_BASE"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .salon: return "Salon"
            case .suite: return "Suite"
            case .mobile: return "Mobile base"
            }
        }
    }

    /// The pro already has at least one location (decides the "make primary" default).
    let hasExistingLocations: Bool
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionModel.self) private var session

    @State private var kind: Kind = .salon
    @State private var name = ""
    @State private var picked: PlaceDetails?
    @State private var zip = ""
    @State private var radiusMiles = 25
    @State private var advanceNoticeMinutes = 15
    @State private var makePrimary: Bool
    @State private var saving = false
    @State private var errorText: String?

    init(hasExistingLocations: Bool, onSaved: @escaping () -> Void) {
        self.hasExistingLocations = hasExistingLocations
        self.onSaved = onSaved
        _makePrimary = State(initialValue: !hasExistingLocations)
    }

    private var canSave: Bool {
        guard !saving else { return false }
        switch kind {
        case .salon, .suite:
            return picked != nil
        case .mobile:
            return zip.trimmingCharacters(in: .whitespaces).count >= 3
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Add where clients can book you. New locations start as a draft — publish them from the Locations screen to go bookable.")
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textSecondary)

                    LocationField(label: "Location type") {
                        Picker("", selection: $kind) {
                            ForEach(Kind.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    LocationField(label: "Name (optional)") { nameField }

                    if kind == .mobile {
                        LocationField(label: "Base ZIP code") { zipField }
                        LocationField(label: "Travel radius") { radiusStepper }
                    } else {
                        LocationField(label: "Address") {
                            PlacesAddressSearchField(
                                picked: $picked,
                                placeholder: "Search your address",
                                disabled: saving
                            )
                        }
                    }

                    LocationField(label: "Booking lead time") {
                        advanceNoticeMenu(selection: $advanceNoticeMinutes)
                    }

                    Toggle(isOn: $makePrimary) {
                        Text("Make this my primary location")
                            .font(BrandFont.body(14))
                            .foregroundStyle(BrandColor.textPrimary)
                    }
                    .tint(BrandColor.accent)

                    if let errorText {
                        Text(errorText)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.ember)
                    }

                    saveButton
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Add location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .tint(BrandColor.textSecondary)
                }
            }
            .tint(BrandColor.accent)
        }
    }

    private var nameField: some View {
        TextField("e.g. Downtown studio", text: $name)
            .font(BrandFont.body(15))
            .foregroundStyle(BrandColor.textPrimary)
            .textInputAutocapitalization(.words)
            .disabled(saving)
            .locationInputBackground()
    }

    private var zipField: some View {
        TextField("e.g. 94110", text: $zip)
            .font(BrandFont.body(15))
            .foregroundStyle(BrandColor.textPrimary)
            .keyboardType(.numberPad)
            .disabled(saving)
            .locationInputBackground()
    }

    private var radiusStepper: some View {
        Stepper(value: $radiusMiles, in: 1...200) {
            Text("\(radiusMiles) miles")
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textPrimary)
        }
        .disabled(saving)
    }

    private var saveButton: some View {
        Button(action: performSave) {
            Text(saving ? "Adding…" : "Add location")
                .font(BrandFont.body(16, .semibold))
                .foregroundStyle(BrandColor.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canSave ? BrandColor.accent : BrandColor.accent.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
    }

    private func performSave() {
        guard canSave else { return }
        saving = true
        errorText = nil

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName: String? = trimmedName.isEmpty ? nil : trimmedName

        Task {
            do {
                switch kind {
                case .salon, .suite:
                    guard let placeId = picked?.placeId else { saving = false; return }
                    try await session.client.proLocations.createFixed(
                        kind: kind.rawValue,
                        placeId: placeId,
                        name: cleanName,
                        advanceNoticeMinutes: advanceNoticeMinutes,
                        makePrimary: makePrimary)
                case .mobile:
                    try await session.client.proLocations.createMobileBase(
                        postalCode: zip.trimmingCharacters(in: .whitespaces),
                        radiusMiles: radiusMiles,
                        name: cleanName,
                        advanceNoticeMinutes: advanceNoticeMinutes,
                        makePrimary: makePrimary)
                }
                onSaved()
                dismiss()
            } catch let apiError as APIError {
                errorText = apiError.userMessage
                saving = false
            } catch {
                errorText = "Could not add that location. Try again."
                saving = false
            }
        }
    }
}

// MARK: - Edit

struct ProLocationEditSheet: View {
    let location: ProLocationSummary
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionModel.self) private var session

    @State private var name: String
    @State private var advanceNoticeMinutes: Int
    @State private var makePrimary: Bool
    @State private var zip: String
    @State private var radiusMiles = 25
    @State private var radiusEdited = false
    @State private var saving = false
    @State private var deleting = false
    @State private var errorText: String?
    @State private var showRemoveConfirm = false

    init(location: ProLocationSummary, onSaved: @escaping () -> Void) {
        self.location = location
        self.onSaved = onSaved
        _name = State(initialValue: location.name ?? "")
        _advanceNoticeMinutes = State(initialValue: location.advanceNoticeMinutes ?? 15)
        _makePrimary = State(initialValue: location.isPrimary)
        _zip = State(initialValue: location.postalCode ?? "")
    }

    private var canSave: Bool { !saving && !deleting }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    LocationField(label: "Name") { nameField }

                    if location.isMobileBase {
                        LocationField(label: "Base ZIP code") { zipField }
                        LocationField(label: "Travel radius") {
                            VStack(alignment: .leading, spacing: 4) {
                                radiusStepper
                                Text("Leave unchanged to keep your current radius.")
                                    .font(BrandFont.body(11))
                                    .foregroundStyle(BrandColor.textMuted)
                            }
                        }
                    }

                    LocationField(label: "Booking lead time") {
                        advanceNoticeMenu(selection: $advanceNoticeMinutes)
                    }

                    primaryControl

                    if !location.isBookable { draftNote }

                    if let errorText {
                        Text(errorText)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.ember)
                    }

                    saveButton

                    Button(role: .destructive) { showRemoveConfirm = true } label: {
                        Text(deleting ? "Removing…" : "Remove location")
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.ember)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .disabled(saving || deleting)
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Edit location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .tint(BrandColor.textSecondary)
                }
            }
            .tint(BrandColor.accent)
            .confirmationDialog(
                "Remove this location?",
                isPresented: $showRemoveConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove location", role: .destructive) { performDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Any bookings tied to it stay on record — it’s just hidden and can no longer be booked.")
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(proLocationDisplayLabel(location))
                .font(BrandFont.body(16, .bold))
                .foregroundStyle(BrandColor.textPrimary)
            if let address = location.formattedAddress, !address.isEmpty {
                Text(address)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            }
            if let tz = location.timeZone, !tz.isEmpty {
                Text("Time zone: \(tz)")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private var nameField: some View {
        TextField("Location name", text: $name)
            .font(BrandFont.body(15))
            .foregroundStyle(BrandColor.textPrimary)
            .textInputAutocapitalization(.words)
            .disabled(saving || deleting)
            .locationInputBackground()
    }

    private var zipField: some View {
        TextField("e.g. 94110", text: $zip)
            .font(BrandFont.body(15))
            .foregroundStyle(BrandColor.textPrimary)
            .keyboardType(.numberPad)
            .disabled(saving || deleting)
            .locationInputBackground()
    }

    private var radiusStepper: some View {
        Stepper(value: $radiusMiles, in: 1...200) {
            Text("\(radiusMiles) miles")
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textPrimary)
        }
        .disabled(saving || deleting)
        .onChange(of: radiusMiles) { _, _ in radiusEdited = true }
    }

    @ViewBuilder
    private var primaryControl: some View {
        if location.isPrimary {
            HStack(spacing: 8) {
                BrandPill(text: "PRIMARY", tint: BrandColor.accent)
                Text("Set another location as primary to change this.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        } else {
            Toggle(isOn: $makePrimary) {
                Text("Make this my primary location")
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textPrimary)
            }
            .tint(BrandColor.accent)
        }
    }

    private var draftNote: some View {
        Text("This location is a draft. Publish it from the Locations screen to make it bookable.")
            .font(BrandFont.body(12))
            .foregroundStyle(BrandColor.amber)
    }

    private var saveButton: some View {
        Button(action: performSave) {
            Text(saving ? "Saving…" : "Save changes")
                .font(BrandFont.body(16, .semibold))
                .foregroundStyle(BrandColor.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canSave ? BrandColor.accent : BrandColor.accent.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canSave)
    }

    // MARK: Actions

    private func performSave() {
        guard canSave else { return }
        saving = true
        errorText = nil

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName: String? = trimmedName.isEmpty ? nil : trimmedName
        let wantsPrimary = !location.isPrimary && makePrimary
        let trimmedZip = zip.trimmingCharacters(in: .whitespaces)
        let zipChanged =
            location.isMobileBase && !trimmedZip.isEmpty && trimmedZip != (location.postalCode ?? "")

        Task {
            do {
                try await session.client.proLocations.update(
                    id: location.id,
                    name: cleanName,
                    isPrimary: wantsPrimary ? true : nil,
                    advanceNoticeMinutes: advanceNoticeMinutes)

                if location.isMobileBase, zipChanged || radiusEdited {
                    try await session.client.proLocations.updateMobileBase(
                        id: location.id,
                        postalCode: zipChanged ? trimmedZip : nil,
                        radiusMiles: radiusEdited ? radiusMiles : nil)
                }

                onSaved()
                dismiss()
            } catch let apiError as APIError {
                errorText = apiError.userMessage
                saving = false
            } catch {
                errorText = "Could not save changes. Try again."
                saving = false
            }
        }
    }

    private func performDelete() {
        deleting = true
        errorText = nil
        Task {
            do {
                try await session.client.proLocations.remove(id: location.id)
                onSaved()
                dismiss()
            } catch let apiError as APIError {
                errorText = apiError.userMessage
                deleting = false
            } catch {
                errorText = "Could not remove that location. Try again."
                deleting = false
            }
        }
    }
}
