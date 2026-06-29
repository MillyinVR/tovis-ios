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
    /// Bookable locations only (create must pin to one).
    let locations: [ProLocationSummary]
    let timeZone: TimeZone
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionModel.self) private var session

    @State private var start: Date
    @State private var end: Date
    @State private var note: String
    @State private var locationId: String?
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
        }
    }

    // MARK: - Validation (mirrors server `validateBlockWindow`: 15min–24h)

    private var durationMinutes: Int {
        Int(end.timeIntervalSince(start) / 60)
    }
    private var windowValid: Bool {
        durationMinutes >= 15 && durationMinutes <= 24 * 60
    }
    private var canSave: Bool {
        !saving && !deleting && windowValid && (isEditing || locationId != nil)
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

                    // Location is fixed on edit (the PATCH route doesn't move it);
                    // only offer a picker on create when there's a real choice.
                    if !isEditing && locations.count > 1 {
                        field("Location") { locationMenu }
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
                Button(locationLabel(location)) { locationId = location.id }
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
        return locationLabel(match)
    }
    private func locationLabel(_ location: ProLocationSummary) -> String {
        location.name ?? location.formattedAddress ?? location.type?.capitalized ?? "Location"
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
                    guard let locationId else { saving = false; return }
                    try await session.client.proCalendar.createBlock(
                        startsAt: ProCalendarGrid.iso(start),
                        endsAt: ProCalendarGrid.iso(end),
                        note: trimmed.isEmpty ? nil : trimmed,
                        locationId: locationId)
                case let .edit(block):
                    // Send the (possibly empty) note so clearing it persists.
                    try await session.client.proCalendar.updateBlock(
                        id: block.id,
                        startsAt: ProCalendarGrid.iso(start),
                        endsAt: ProCalendarGrid.iso(end),
                        note: trimmed)
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
