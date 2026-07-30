// Create / edit a blocked-time window — the native counterpart of the web
// `BlockTimeModal` (create) + `EditBlockModal` (edit/delete). Copy is quoted from
// the brand `proCalendar.blockTimeModal` / `editBlockModal`. Posts to
// `/pro/calendar/blocked(/[id])`; the server validates the 15min–24h window and
// rejects overlaps with a user-facing message we surface inline.
import SwiftUI
import TovisKit

struct ProBlockTimeSheet: View {
    enum Mode: Equatable {
        case create
        case edit(ProCalendarBlock)
    }

    let mode: Mode
    /// The pro's bookable locations. Create picks one (or "all locations"); edit
    /// can now MOVE the block between them.
    let locations: [ProLocationSummary]
    let timeZone: TimeZone
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionModel.self) private var session

    @State private var start: Date
    @State private var end: Date
    @State private var note: String
    @State private var locationId: String?
    /// Block EVERY location instead of one. On create this posts no `locationId`;
    /// on edit it sends an explicit null. Either way the server stores
    /// `locationId: null` — the block then occupies this pro's time at every
    /// location, which is how every conflict and availability read already
    /// interprets it (tovis-app #794).
    @State private var blockAllLocations = false
    /// The scope the block had when the sheet opened, so an untouched save sends
    /// no `locationId` at all and cannot widen the block by accident.
    private let originalLocationId: String?
    @State private var saving = false
    @State private var deleting = false
    @State private var errorText: String?
    @State private var showDeleteConfirm = false

    private var isEditing: Bool { if case .edit = mode { return true } else { return false } }

    init(
        mode: Mode,
        locations: [ProLocationSummary],
        defaultStart: Date,
        timeZone: TimeZone,
        onSaved: @escaping () -> Void
    ) {
        self.mode = mode
        self.locations = locations
        self.timeZone = timeZone
        self.onSaved = onSaved

        switch mode {
        case .create:
            _start = State(initialValue: defaultStart)
            _end = State(initialValue: defaultStart.addingTimeInterval(3600))
            _note = State(initialValue: "")
            _locationId = State(initialValue: (locations.first { $0.isPrimary } ?? locations.first)?.id)
        case let .edit(block):
            let parsedStart = Wire.date(block.startsAt) ?? defaultStart
            let parsedEnd = Wire.date(block.endsAt) ?? parsedStart.addingTimeInterval(3600)
            _start = State(initialValue: parsedStart)
            _end = State(initialValue: parsedEnd)
            _note = State(initialValue: block.note ?? "")
            _locationId = State(initialValue: block.locationId)
            // A block with no location of its own already applies everywhere.
            _blockAllLocations = State(initialValue: block.locationId == nil)
        }

        switch mode {
        case .create:
            originalLocationId = nil
        case let .edit(block):
            originalLocationId = block.locationId
        }
    }

    /// What the PATCH should say about the location: nothing at all unless the
    /// pro actually changed it.
    private var scopeUpdate: BlockScopeUpdate {
        let selected = blockAllLocations ? nil : locationId

        guard selected != originalLocationId else { return .unchanged }

        guard let selected else { return .allLocations }

        return .location(selected)
    }

    // MARK: - Validation (mirrors server `validateBlockWindow`: 15min–24h)

    private var durationMinutes: Int {
        Int(end.timeIntervalSince(start) / 60)
    }
    private var windowValid: Bool {
        durationMinutes >= 15 && durationMinutes <= 24 * 60
    }
    private var canSave: Bool {
        !saving && !deleting && windowValid
            && (blockAllLocations || locationId != nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(description)
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textSecondary)

                    field("Start") {
                        DatePicker("", selection: $start, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .datePickerStyle(.compact)
                    }

                    field("End") {
                        DatePicker("", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .datePickerStyle(.compact)
                    }

                    if !windowValid {
                        Text("Block must be between 15 minutes and 24 hours.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.amber)
                    }

                    // Offered on create AND edit: a block can be moved between
                    // locations, which is also the only way to re-home one that a
                    // location delete orphaned. Hidden when there is no real
                    // choice to make.
                    if locations.count > 1 {
                        field("Location") {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle(isOn: $blockAllLocations) {
                                    Text("Block all locations")
                                        .font(BrandFont.body(15))
                                        .foregroundStyle(BrandColor.textPrimary)
                                }
                                .tint(BrandColor.accent)
                                .disabled(saving)

                                if blockAllLocations {
                                    Text("This block applies to every location.")
                                        .font(BrandFont.body(12))
                                        .foregroundStyle(BrandColor.textSecondary)
                                } else {
                                    locationMenu
                                }
                            }
                        }
                    }

                    // With one location there is nothing to pick, but an existing
                    // block that applies everywhere must still SAY so rather than
                    // reading as a block at that one location.
                    if locations.count <= 1, blockAllLocations {
                        field("Location") {
                            Text("All locations")
                                .font(BrandFont.body(15))
                                .foregroundStyle(BrandColor.textPrimary)
                        }
                    }

                    field("Reason") {
                        TextField("Lunch, errands, prep time…", text: $note, axis: .vertical)
                            .font(BrandFont.body(15))
                            .foregroundStyle(BrandColor.textPrimary)
                            .lineLimit(1...3)
                            .textInputAutocapitalization(.sentences)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .background(BrandColor.bgSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    if let errorText {
                        Text(errorText)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.ember)
                    }

                    saveButton

                    if isEditing {
                        Button(role: .destructive) { showDeleteConfirm = true } label: {
                            Text(deleting ? "Deleting…" : "Delete block")
                                .font(BrandFont.body(15, .semibold))
                                .foregroundStyle(BrandColor.ember)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .disabled(saving || deleting)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .tint(BrandColor.textSecondary)
                }
            }
            .tint(BrandColor.accent)
            .environment(\.timeZone, timeZone) // render pickers in the calendar zone
            .confirmationDialog(
                "Delete this blocked time?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete block", role: .destructive) { performDelete() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Pieces

    private var saveButton: some View {
        Button(action: performSave) {
            Text(saving ? savingLabel : saveLabel)
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

    private var locationMenu: some View {
        Menu {
            ForEach(locations) { location in
                Button(proLocationDisplayLabel(location)) { locationId = location.id }
            }
        } label: {
            HStack {
                Text(selectedLocationLabel)
                    .font(BrandFont.body(15))
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BrandColor.textMuted)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(BrandFont.mono(11))
                .tracking(0.8)
                .foregroundStyle(BrandColor.textMuted)
            content()
        }
    }

    // MARK: - Labels (brand copy)

    private var title: String { isEditing ? "Edit blocked time" : "Block time" }
    private var description: String {
        isEditing
            ? "Update or remove this blocked window from your calendar."
            : "Hold time on your calendar so clients cannot book over it."
    }
    private var saveLabel: String { isEditing ? "Save changes" : "Create block" }
    private var savingLabel: String { isEditing ? "Saving…" : "Creating…" }

    private var selectedLocationLabel: String {
        guard let locationId, let match = locations.first(where: { $0.id == locationId })
        else { return "Select location" }
        return proLocationDisplayLabel(match)
    }

    // MARK: - Actions

    private func performSave() {
        guard canSave else { return }
        saving = true
        errorText = nil
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                switch mode {
                case .create:
                    // Unscoped ("all locations") is a DELIBERATE nil; a location
                    // the pro simply never picked is not, and must still refuse.
                    let scope = blockAllLocations ? nil : locationId
                    guard blockAllLocations || scope != nil else {
                        saving = false
                        return
                    }
                    try await session.client.proCalendar.createBlock(
                        startsAt: ProCalendarGrid.iso(start),
                        endsAt: ProCalendarGrid.iso(end),
                        note: trimmed.isEmpty ? nil : trimmed,
                        locationId: scope)
                case let .edit(block):
                    // Send the (possibly empty) note so clearing it persists. The
                    // scope goes only if the pro changed it — see `scopeUpdate`.
                    try await session.client.proCalendar.updateBlock(
                        id: block.id,
                        startsAt: ProCalendarGrid.iso(start),
                        endsAt: ProCalendarGrid.iso(end),
                        note: trimmed,
                        scope: scopeUpdate)
                }
                onSaved()
                dismiss()
            } catch let apiError as APIError {
                errorText = apiError.userMessage
                saving = false
            } catch {
                errorText = isEditing
                    ? "Could not update blocked time. Try again."
                    : "Could not create blocked time. Try again."
                saving = false
            }
        }
    }

    private func performDelete() {
        guard case let .edit(block) = mode else { return }
        deleting = true
        errorText = nil
        Task {
            do {
                try await session.client.proCalendar.deleteBlock(id: block.id)
                onSaved()
                dismiss()
            } catch let apiError as APIError {
                errorText = apiError.userMessage
                deleting = false
            } catch {
                errorText = "Could not delete blocked time. Try again."
                deleting = false
            }
        }
    }
}
