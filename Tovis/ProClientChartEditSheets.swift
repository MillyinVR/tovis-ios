// Per-tab write forms for the pro client chart — native ports of the web sibling
// forms (`EditAlertBannerForm`, `EditDoNotRebookForm`, `EditProfileContextForm`,
// `NewAllergyForm`). Each POSTs/PATCHes/PUTs its existing `/pro/clients/{id}/…`
// route (no backend change), then calls `onSaved` so the chart reloads. Free text
// is encrypted server-side; the client only sends plaintext.
import SwiftUI
import TovisKit

// MARK: - Shared field style

private extension View {
    /// Bordered box matching `ProAddNoteSheet`'s editor treatment.
    func chartFieldBackground() -> some View {
        padding(10)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .font(BrandFont.body(15))
            .foregroundStyle(BrandColor.textPrimary)
    }
}

// MARK: - Alert banner

/// PATCH /pro/clients/{id}/alert — the pinned safety banner. Blank clears it.
struct ProEditAlertBannerSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let clientId: String
    let current: String?
    var onSaved: () -> Void

    @State private var text: String
    @State private var saving = false
    @State private var error: String?

    init(clientId: String, current: String?, onSaved: @escaping () -> Void) {
        self.clientId = clientId
        self.current = current
        self.onSaved = onSaved
        _text = State(initialValue: current ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("A short safety alert pinned to the top of this client's chart.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)

                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .chartFieldBackground()

                    if current?.isEmpty == false {
                        Button(role: .destructive) {
                            text = ""
                            Task { await save() }
                        } label: {
                            Text("Remove alert").font(BrandFont.body(14, .semibold))
                        }
                        .tint(BrandColor.ember)
                    }

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle(current?.isEmpty == false ? "Edit alert" : "Add alert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving)
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
            try await session.client.proClients.updateAlertBanner(
                clientId: clientId,
                alertBanner: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onSaved()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save the alert. Try again."
        }
    }
}

// MARK: - Do not rebook

/// PUT/DELETE /pro/clients/{id}/do-not-rebook — the author-scoped flag.
struct ProDoNotRebookSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let clientId: String
    let active: Bool
    let currentReason: String?
    var onSaved: () -> Void

    @State private var reason: String
    @State private var saving = false
    @State private var error: String?

    init(clientId: String, active: Bool, currentReason: String?, onSaved: @escaping () -> Void) {
        self.clientId = clientId
        self.active = active
        self.currentReason = currentReason
        self.onSaved = onSaved
        _reason = State(initialValue: currentReason ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Reason (factual)")
                        .font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textSecondary)

                    TextEditor(text: $reason)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .chartFieldBackground()

                    Text("Private to you — never shown to other pros or the client. Keep the reason strictly factual (conduct or safety), not personal characteristics.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)

                    if active {
                        Button(role: .destructive) {
                            Task { await clear() }
                        } label: {
                            Text("Remove flag").font(BrandFont.body(14, .semibold))
                        }
                        .tint(BrandColor.ember)
                    }

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle(active ? "Edit do-not-rebook" : "Flag do not rebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save flag") { Task { await save() } }
                        .disabled(saving)
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
            try await session.client.proClients.setDoNotRebook(
                clientId: clientId,
                reason: reason.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onSaved()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save the flag. Try again."
        }
    }

    private func clear() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await session.client.proClients.clearDoNotRebook(clientId: clientId)
            onSaved()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t clear the flag. Try again."
        }
    }
}

// MARK: - Profile context

/// PATCH /pro/clients/{id}/profile-context — pro-captured occupation + social handle.
struct ProEditProfileContextSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let clientId: String
    var onSaved: () -> Void

    @State private var occupation: String
    @State private var socialHandle: String
    @State private var saving = false
    @State private var error: String?

    init(clientId: String, occupation: String, socialHandle: String, onSaved: @escaping () -> Void) {
        self.clientId = clientId
        self.onSaved = onSaved
        _occupation = State(initialValue: occupation)
        // Strip a leading @ for display; the route re-normalizes on save anyway.
        _socialHandle = State(initialValue: socialHandle.hasPrefix("@") ? String(socialHandle.dropFirst()) : socialHandle)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field(title: "Occupation", placeholder: "e.g. Nurse (rotating shifts)", text: $occupation)
                    field(title: "Social handle (for tagging)", placeholder: "@theirhandle", text: $socialHandle)

                    Text("Occupation is stored encrypted. The social handle is for tagging the client on socials.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Chart context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(saving)
                        .tint(BrandColor.accent)
                }
            }
            .tint(BrandColor.accent)
        }
    }

    private func field(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textSecondary)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .chartFieldBackground()
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await session.client.proClients.updateProfileContext(
                clientId: clientId,
                occupation: occupation.trimmingCharacters(in: .whitespacesAndNewlines),
                socialHandle: socialHandle.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onSaved()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save the context. Try again."
        }
    }
}

// MARK: - Add allergy

/// POST /pro/clients/{id}/allergies — record an allergy/sensitivity.
struct ProAddAllergySheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let clientId: String
    var onSaved: () -> Void

    @State private var label = ""
    @State private var description = ""
    @State private var severity = "MODERATE"
    @State private var saving = false
    @State private var error: String?

    private let severities = ["LOW", "MODERATE", "HIGH", "CRITICAL"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Allergy / sensitivity")
                            .font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textSecondary)
                        TextField("Ex: PPD, latex, lash glue, fragrance", text: $label)
                            .chartFieldBackground()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description (optional)")
                            .font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textSecondary)
                        TextEditor(text: $description)
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .chartFieldBackground()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Severity")
                            .font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textSecondary)
                        Picker("Severity", selection: $severity) {
                            ForEach(severities, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Add allergy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Add") { Task { await save() } }
                        .disabled(saving || label.trimmingCharacters(in: .whitespaces).isEmpty)
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
            try await session.client.proClients.addAllergy(
                clientId: clientId,
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                description: description.trimmedOrNil,
                severity: severity
            )
            onSaved()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t add the allergy. Try again."
        }
    }
}
