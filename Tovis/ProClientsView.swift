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
    @State private var recent: [ProClientSummary] = []
    @State private var other: [ProClientSummary] = []
    @State private var loading = true
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var showAdd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                addClientCard

                if loading {
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 60)
                } else if let error {
                    Text(error).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    if !recent.isEmpty {
                        section(title: query.isEmpty ? "Recent" : "Matches", clients: recent)
                    }
                    if !other.isEmpty {
                        section(title: "More clients", clients: other)
                    }
                    if recent.isEmpty && other.isEmpty {
                        Text(query.isEmpty ? "No clients yet." : "No clients match “\(query)”.")
                            .font(BrandFont.body(14)).foregroundStyle(BrandColor.textMuted)
                            .frame(maxWidth: .infinity).padding(.top, 50)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Clients")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .searchable(text: $query, prompt: "Search clients")
        .onChange(of: query) { debouncedSearch() }
        .task { if loading { await load() } }
        .sheet(isPresented: $showAdd) {
            ProAddClientSheet { Task { await load() } }
        }
        .tint(BrandColor.accent)
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

    private func section(title: String, clients: [ProClientSummary]) -> some View {
        BrandSection(title: title) {
            VStack(spacing: 10) {
                ForEach(clients) { client in row(client) }
            }
        }
    }

    @ViewBuilder
    private func row(_ client: ProClientSummary) -> some View {
        if client.canViewClient {
            NavigationLink { ProClientDetailView(client: client) } label: { rowBody(client) }
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
                    if let sub = client.email ?? client.phone {
                        Text(sub).font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted).lineLimit(1)
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

    private func debouncedSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            await load()
        }
    }

    private func load() async {
        error = nil
        do {
            let res = try await session.client.proClients.search(query: query)
            recent = res.recentClients
            other = res.otherClients
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t load your clients."
        }
        loading = false
    }
}

// MARK: - Client detail

struct ProClientDetailView: View {
    @Environment(SessionModel.self) private var session
    let client: ProClientSummary

    @State private var addresses: [ProClientAddress] = []
    @State private var loadingAddresses = true
    @State private var showAddNote = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if client.phone != nil || client.email != nil {
                    BrandSection(title: "Contact") {
                        VStack(spacing: 10) {
                            if let phone = client.phone {
                                contactRow("phone.fill", phone, URL(string: "tel:\(phone.filter { !$0.isWhitespace })"))
                            }
                            if let email = client.email {
                                contactRow("envelope.fill", email, URL(string: "mailto:\(email)"))
                            }
                        }
                    }
                }

                BrandSection(title: "Service addresses") {
                    if loadingAddresses {
                        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.vertical, 8)
                    } else if addresses.isEmpty {
                        BrandSurface {
                            Text("No saved service addresses.")
                                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        VStack(spacing: 10) {
                            ForEach(addresses) { addr in
                                BrandSurface {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(addr.label).font(BrandFont.body(14, .semibold))
                                                .foregroundStyle(BrandColor.textPrimary)
                                            if addr.isDefault { BrandPill(text: "Default", tint: BrandColor.accent) }
                                        }
                                        Text(addr.formattedAddress)
                                            .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }

                Button { showAddNote = true } label: {
                    Label("Add a note", systemImage: "square.and.pencil")
                        .font(BrandFont.body(16, .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .foregroundStyle(BrandColor.textPrimary)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(BrandColor.textMuted.opacity(0.3), lineWidth: 1))
                }

                Text("Full chart history (past notes, allergies, formulas) lives on the web for now.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle(client.fullName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { await loadAddresses() }
        .sheet(isPresented: $showAddNote) {
            ProAddNoteSheet(clientId: client.id)
        }
        .tint(BrandColor.accent)
    }

    private var header: some View {
        BrandSurface {
            HStack(spacing: 14) {
                BrandAvatar(name: client.fullName, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(client.fullName)
                        .font(BrandFont.display(20, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("Client").font(BrandFont.mono(11)).foregroundStyle(BrandColor.textMuted)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func contactRow(_ icon: String, _ label: String, _ url: URL?) -> some View {
        let inner = BrandSurface {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(BrandColor.accent).frame(width: 24)
                Text(label).font(BrandFont.body(14)).foregroundStyle(url != nil ? BrandColor.accent : BrandColor.textSecondary)
                Spacer()
            }
        }
        if let url { Link(destination: url) { inner } } else { inner }
    }

    private func loadAddresses() async {
        addresses = (try? await session.client.proClients.serviceAddresses(clientId: client.id)) ?? []
        loadingAddresses = false
    }
}

// MARK: - Add note

struct ProAddNoteSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let clientId: String

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
