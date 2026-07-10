// Pro Reminders — the native counterpart of the web `/pro/reminders` page, backed
// by GET/POST /api/v1/pro/reminders (+ .../{id}/complete). Routes already exist, so
// this is an iOS-only port. These are the pro's own follow-up / rebook / product
// check-in to-dos ("Check in on color fade", "DM bridal party count") — distinct
// from the appointment-reminder CADENCE that lives under "Appointment reminders".
// Add a reminder (optionally linked to a client), see the open list ordered by due
// date, and mark one done. Reached from the pro profile's Business section.
import SwiftUI
import TovisKit

struct ProRemindersView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded([ProReminder])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var showCreate = false
    // The reminder currently being marked done (drives its row spinner + disable).
    @State private var completingId: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 60)
                case let .failed(message):
                    errorState(message)
                case let .loaded(reminders):
                    content(reminders)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
        .onChange(of: session.refreshTick) { Task { await load() } }
        .sheet(isPresented: $showCreate) {
            ProReminderCreateSheet { await load() }
        }
    }

    @ViewBuilder
    private func content(_ reminders: [ProReminder]) -> some View {
        let open = reminders.filter { !$0.isCompleted }
        // Recently completed: newest-first, capped at 20 (mirrors the web page).
        let completed = reminders
            .filter { $0.isCompleted }
            .sorted { ($0.completedAt ?? "") > ($1.completedAt ?? "") }
            .prefix(20)

        Text("Follow-ups, rebooks, product check-ins — all the stuff Future You would forget.")
            .font(BrandFont.body(13))
            .foregroundStyle(BrandColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        addButton

        BrandSection(title: "Upcoming & open", trailing: open.isEmpty ? nil : "\(open.count)") {
            if open.isEmpty {
                emptyCard("Nothing on your radar yet. Future you is suspicious.")
            } else {
                VStack(spacing: 12) {
                    ForEach(open) { openRow($0) }
                }
            }
        }

        if !completed.isEmpty {
            BrandSection(title: "Recently completed", trailing: "\(completed.count)") {
                VStack(spacing: 10) {
                    ForEach(completed) { completedRow($0) }
                }
            }
        }
    }

    private var addButton: some View {
        Button {
            showCreate = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                Text("Add a reminder")
            }
            .font(BrandFont.body(15, .semibold))
            .foregroundStyle(BrandColor.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(BrandColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func openRow(_ reminder: ProReminder) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(reminder.title)
                            .font(BrandFont.body(14, .bold))
                            .foregroundStyle(BrandColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Wire.dateTime(reminder.dueAt, timeZone: nil))
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                    Spacer(minLength: 8)
                    typePill(reminder.type)
                }

                if let client = reminder.client, !client.displayName.isEmpty {
                    metaLine("Client", client.displayName)
                }
                if let booking = reminder.booking {
                    metaLine("Booking", bookingLabel(booking))
                }
                if let body = reminder.body, !body.isEmpty {
                    Text(body)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                markDoneButton(reminder)
                    .padding(.top, 2)
            }
        }
    }

    private func markDoneButton(_ reminder: ProReminder) -> some View {
        Button {
            Task { await complete(reminder) }
        } label: {
            Group {
                if completingId == reminder.id {
                    ProgressView().tint(BrandColor.emerald)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                        Text("Mark done")
                    }
                }
            }
            .font(BrandFont.body(12, .semibold))
            .foregroundStyle(BrandColor.emerald)
            .padding(.vertical, 7)
            .padding(.horizontal, 14)
            .overlay(Capsule().stroke(BrandColor.emerald.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(completingId != nil)
    }

    private func completedRow(_ reminder: ProReminder) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Due \(Wire.dateTime(reminder.dueAt, timeZone: nil))")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
                if let completedAt = reminder.completedAt {
                    Text("Completed \(Wire.dateTime(completedAt, timeZone: nil))")
                        .font(BrandFont.body(11))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
    }

    private func metaLine(_ label: String, _ value: String) -> some View {
        (Text("\(label): ").foregroundStyle(BrandColor.textMuted)
            + Text(value).foregroundStyle(BrandColor.textSecondary))
            .font(BrandFont.body(12))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func typePill(_ type: String) -> some View {
        Text(type.lowercased())
            .font(BrandFont.mono(10))
            .tracking(0.6)
            .foregroundStyle(BrandColor.textSecondary)
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(BrandColor.bgSecondary)
            .clipShape(Capsule())
    }

    /// "Balayage on Tue, Jul 21 · 10:00 AM" in the booking's own zone.
    private func bookingLabel(_ booking: ProReminderBooking) -> String {
        let service = booking.service?.name ?? "Service"
        guard let scheduledFor = booking.scheduledFor else { return service }
        let when = Wire.dateTime(scheduledFor, timeZone: booking.locationTimeZone)
        return when.isEmpty ? service : "\(service) on \(when)"
    }

    private func emptyCard(_ message: String) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            Text(message)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
        .padding(.top, 50)
    }

    private func load() async {
        do {
            let reminders = try await session.client.proReminders.list()
            phase = .loaded(reminders)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn't load your reminders just now. Please try again.")
        }
    }

    private func complete(_ reminder: ProReminder) async {
        guard completingId == nil else { return }
        completingId = reminder.id
        defer { completingId = nil }
        do {
            try await session.client.proReminders.complete(id: reminder.id)
            await load()
        } catch {
            // Leave the row as-is; a reload on next pull will reconcile.
        }
    }
}

// MARK: - Create sheet

/// Create a reminder (web `/pro/reminders` "Add a reminder" form). Title + due
/// date are required; notes and a linked client are optional. Unlike the web
/// `datetime-local` field, the native picker yields a real instant, so the stored
/// `dueAt` is unambiguous. Only clients the pro can currently view are offered
/// (the route re-checks). Every reminder is `GENERAL`, matching the web form.
struct ProReminderCreateSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Called after a successful create so the list reloads.
    var onCreated: () async -> Void

    @State private var title = ""
    @State private var notes = ""
    @State private var dueAt = Date().addingTimeInterval(60 * 60)
    @State private var clients: [ProClientSummary] = []
    @State private var selectedClientId: String?
    @State private var saving = false
    @State private var error: String?

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !saving
    }

    private var selectedClientName: String {
        guard let selectedClientId,
              let match = clients.first(where: { $0.id == selectedClientId })
        else { return "No specific client" }
        return match.fullName
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Example: “Check in on color fade”, “DM bridal party count”, “Follow up on retail purchase”.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    EditField(label: "Title") {
                        TextField("Follow up with client", text: $title)
                            .font(BrandFont.body(15))
                            .foregroundStyle(BrandColor.textPrimary)
                            .editFieldBox()
                    }

                    EditField(label: "Notes (optional)") {
                        TextField(
                            "e.g. ask how her scalp handled last lightening",
                            text: $notes,
                            axis: .vertical
                        )
                        .lineLimit(3...6)
                        .font(BrandFont.body(15))
                        .foregroundStyle(BrandColor.textPrimary)
                        .editFieldBox()
                    }

                    EditField(label: "Due date & time") {
                        DatePicker(
                            "",
                            selection: $dueAt,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .tint(BrandColor.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .editFieldBox()
                    }

                    if !clients.isEmpty {
                        EditField(label: "Linked client (optional)") { clientMenu }
                    }

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Add a reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving {
                            ProgressView().tint(BrandColor.accent)
                        } else {
                            Text("Save").font(BrandFont.body(15, .semibold))
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .task { await loadClients() }
        }
    }

    private var clientMenu: some View {
        Menu {
            Button("No specific client") { selectedClientId = nil }
            ForEach(clients) { client in
                Button(client.fullName) { selectedClientId = client.id }
            }
        } label: {
            HStack {
                Text(selectedClientName)
                    .font(BrandFont.body(15))
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BrandColor.textMuted)
            }
            .editFieldBox()
        }
    }

    /// Only clients the pro can currently open a chart for are linkable — the
    /// route enforces the same gate, so filter to `canViewClient` here.
    private func loadClients() async {
        guard clients.isEmpty else { return }
        if let directory = try? await session.client.proClients.directory() {
            clients = directory.clients.filter { $0.canViewClient }
        }
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await session.client.proReminders.create(
                title: title.trimmingCharacters(in: .whitespaces),
                body: notes.trimmingCharacters(in: .whitespaces),
                dueAt: ProCalendarGrid.iso(dueAt),
                clientId: selectedClientId
            )
            await onCreated()
            dismiss()
        } catch let apiError as APIError {
            error = apiError.userMessage
        } catch {
            self.error = "Couldn't save that reminder. Please try again."
        }
    }
}
