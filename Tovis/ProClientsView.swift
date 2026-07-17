// Pro clients — the native port of web `/pro/clients`. A searchable directory
// (recent + other) → a client detail with contact actions, saved service
// addresses, and an append-only chart note. The full chart HISTORY (existing
// notes/allergies/formula) is server-rendered with no read API yet — that needs
// a backend aggregate GET before it can be ported (noted in the handoff).
import SwiftUI
import TovisKit

struct ProClientsView: View {
    @Environment(SessionModel.self) private var session

    @State private var query = ""
    @State private var all: [ProClientSummary] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showAdd = false

    // Booking-less claim invite (feature-gated server-side; `invitable` is only
    // set when it's on). Tracks the in-flight client + a result alert.
    @State private var invitingId: String?
    @State private var inviteAlert: String?

    // Web `/pro/clients` has no server search — it lists the whole visible set.
    // Native loads that directory once and filters in memory.
    private var filtered: [ProClientSummary] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { c in
            c.fullName.lowercased().contains(q)
                || (c.email?.lowercased().contains(q) ?? false)
                || (c.phone?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Only clients you currently have access to (pending/active/upcoming).")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)

                addClientCard

                if loading {
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 60)
                } else if let error {
                    Text(error).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                } else if all.isEmpty {
                    emptyState
                } else {
                    clientList
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Clients")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .searchable(text: $query, prompt: "Search clients")
        .task { if loading { await load() } }
        .sheet(isPresented: $showAdd) {
            ProAddClientSheet { Task { await load() } }
        }
        .alert(
            "Claim invite",
            isPresented: Binding(
                get: { inviteAlert != nil },
                set: { if !$0 { inviteAlert = nil } }
            ),
            presenting: inviteAlert
        ) { _ in
            Button("OK", role: .cancel) { inviteAlert = nil }
        } message: { Text($0) }
        .tint(BrandColor.accent)
    }

    // "Client list" + "{n} visible" count + the web subtitle, mirroring
    // app/pro/clients/page.tsx.
    private var clientList: some View {
        BrandSection(title: "Client list", trailing: "\(filtered.count) visible") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Only clients with active access are shown here.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)

                if filtered.isEmpty {
                    Text("No clients match “\(query)”.")
                        .font(BrandFont.body(14)).foregroundStyle(BrandColor.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                } else {
                    ForEach(filtered) { client in
                        VStack(alignment: .leading, spacing: 8) {
                            row(client)
                            if client.invitable == true {
                                inviteToClaimButton(client)
                            }
                        }
                    }
                }
            }
        }
    }

    // Web EmptyState copy for a pro with no currently-visible clients.
    private var emptyState: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                Text("No clients with active visibility right now.")
                    .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("Only clients with active access appear here. Share your booking link to bring clients on.")
                    .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
    }

    private var addClientCard: some View {
        BrandSurface {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a client")
                        .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    Text("Add shadow clients and attach bookings + aftercare.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                }
                Spacer()
                Button { showAdd = true } label: {
                    Text("+ Add")
                        .font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        .padding(.vertical, 8).padding(.horizontal, 14)
                        .background(BrandColor.bgSecondary).clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // An UNCLAIMED, booking-less client this pro created — offer to send a claim
    // link so they can take ownership of their history.
    private func inviteToClaimButton(_ client: ProClientSummary) -> some View {
        Button {
            Task { await sendInvite(client) }
        } label: {
            HStack(spacing: 8) {
                if invitingId == client.id {
                    ProgressView().tint(BrandColor.accent).scaleEffect(0.8)
                } else {
                    Image(systemName: "paperplane.fill").font(.system(size: 12, weight: .semibold))
                }
                Text(invitingId == client.id ? "Sending…" : "Invite to claim")
                    .font(BrandFont.body(12, .semibold))
            }
            .foregroundStyle(BrandColor.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandColor.accent.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(invitingId != nil)
        .padding(.bottom, 2)
    }

    private func sendInvite(_ client: ProClientSummary) async {
        guard invitingId == nil else { return }
        invitingId = client.id
        defer { invitingId = nil }
        do {
            let result = try await session.client.proClients.inviteToClaim(clientId: client.id)
            inviteAlert = result.inviteDelivery.queued
                ? "We sent \(client.fullName) a secure link to claim their account."
                : "\(client.fullName) has no email or phone on file. Add one, then invite again."
            // Refresh so the row reflects any state change.
            await load()
        } catch let e as APIError {
            inviteAlert = e.userMessage
        } catch {
            inviteAlert = "Couldn’t send the invite. Please try again."
        }
    }

    @ViewBuilder
    private func row(_ client: ProClientSummary) -> some View {
        if client.canViewClient {
            NavigationLink { ProClientChartView(clientId: client.id, fullName: client.fullName) } label: { rowBody(client) }
                .buttonStyle(.plain)
        } else {
            rowBody(client)   // not viewable → no chart link (mirrors web gating)
        }
    }

    private func rowBody(_ client: ProClientSummary) -> some View {
        BrandSurface {
            HStack(spacing: 12) {
                BrandAvatar(name: client.fullName, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(client.fullName)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    // Web row: "{email || No email}{ • phone}".
                    Text((client.email ?? "No email") + (client.phone.map { " • \($0)" } ?? ""))
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted).lineLimit(1)
                    if let last = client.lastBookingLabel {
                        Text(last).font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted.opacity(0.8)).lineLimit(1)
                    }
                }
                Spacer()
                if client.canViewClient {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
    }

    private func load() async {
        error = nil
        do {
            let res = try await session.client.proClients.directory()
            all = res.clients
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t load your clients."
        }
        loading = false
    }
}

// MARK: - Add note

struct ProAddNoteSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let clientId: String
    /// Optional — the chart passes a reload closure so a new note appears without
    /// leaving the screen. `ProClientChartView` is currently the only caller.
    var onSaved: (() -> Void)? = nil

    @State private var noteText = ""
    @State private var kind = "GENERAL"
    @State private var saving = false
    @State private var error: String?

    private let kinds: [(value: String, label: String)] = [
        ("GENERAL", "General"),
        ("CONSULTATION", "Consultation"),
        ("COMMUNICATION_STYLE", "Communication"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Kind", selection: $kind) {
                        ForEach(kinds, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .pickerStyle(.segmented)

                    TextEditor(text: $noteText)
                        .frame(minHeight: 160)
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .background(BrandColor.bgSecondary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .font(BrandFont.body(15))
                        .foregroundStyle(BrandColor.textPrimary)

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("New note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving || noteText.trimmingCharacters(in: .whitespaces).isEmpty)
                        .tint(BrandColor.accent)
                }
            }
            .tint(BrandColor.accent)
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await session.client.proClients.addNote(clientId: clientId, body: noteText, kind: kind)
            onSaved?()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save the note. Try again."
        }
    }
}

// MARK: - Add a client (NewClientForm parity)

/// Native port of the web NewClientForm — adds a shadow client (POST /pro/clients)
/// with first/last/email required + optional phone. Presented from the clients list.
struct ProAddClientSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    var onAdded: () -> Void

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var saving = false
    @State private var error: String?
    @State private var success = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Add shadow clients and attach bookings + aftercare.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)

                    HStack(spacing: 10) {
                        field("First name *", text: $firstName)
                        field("Last name *", text: $lastName)
                    }
                    field("Email *", text: $email, placeholder: "client@email.com", keyboard: .emailAddress)
                    field("Phone (optional)", text: $phone, placeholder: "For reminders later", keyboard: .phonePad)

                    if let error { Text(error).font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.ember) }
                    if success { Text("Client added.").font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.emerald) }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Add a client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary).disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Add client") { Task { await save() } }
                        .disabled(saving).tint(BrandColor.accent)
                }
            }
            .tint(BrandColor.accent)
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String = "", keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(BrandFont.mono(9)).tracking(0.6).foregroundStyle(BrandColor.textSecondary)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .emailAddress ? .never : .words)
                .autocorrectionDisabled(keyboard == .emailAddress)
                .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
                .padding(12).background(BrandColor.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(saving)
        }
    }

    private func save() async {
        guard !saving else { return }
        let f = firstName.trimmingCharacters(in: .whitespaces)
        let l = lastName.trimmingCharacters(in: .whitespaces)
        let e = email.trimmingCharacters(in: .whitespaces)
        let p = phone.trimmingCharacters(in: .whitespaces)
        if f.isEmpty || l.isEmpty || e.isEmpty {
            error = "First name, last name, and email are required."
            return
        }
        saving = true
        error = nil
        defer { saving = false }
        do {
            _ = try await session.client.proClients.createClient(
                firstName: f, lastName: l, email: e, phone: p.isEmpty ? nil : p
            )
            success = true
            onAdded()
            try? await Task.sleep(nanoseconds: 400_000_000)
            dismiss()
        } catch let err as APIError {
            error = err.userMessage
        } catch {
            self.error = "Network error while creating client."
        }
    }
}
