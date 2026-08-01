// Write forms for the founder-gated client TECHNICAL RECORD — native ports of the
// web sibling forms (`NewFormulaForm`, `NewConsentForm`, `EditPhotoReleaseForm`).
// Each POSTs/PATCHes its existing `/pro/clients/{id}/{formula,consent,photo-release}`
// route (no backend change), then calls `onSaved` so the technical view reloads.
// Free text (formula result notes, consent notes) is encrypted server-side; the
// client sends plaintext. Dates are sent as plain "yyyy-MM-dd" (mirrors the web
// date inputs). Increment 2 of the pro private-client-view parity.
import SwiftUI
import TovisKit

/// Format a picked calendar day as the backend's plain date string.
private func isoDay(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
}

private extension View {
    /// Bordered box matching the other chart sheets' editor treatment.
    func chartFieldBackground() -> some View {
        padding(10)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .font(BrandFont.body(15))
            .foregroundStyle(BrandColor.textPrimary)
    }
}

// MARK: - Add formula

/// POST /pro/clients/{id}/formula — an author-only formula entry. At least one
/// detail is required; the result notes are encrypted server-side.
struct ProAddFormulaSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let clientId: String
    var onSaved: () -> Void

    @State private var brand = ""
    @State private var developer = ""
    @State private var ratio = ""
    @State private var processing = ""
    @State private var resultNotes = ""
    @State private var saving = false
    @State private var error: String?

    private var hasDetail: Bool {
        !brand.trimmed.isEmpty || !developer.trimmed.isEmpty || !ratio.trimmed.isEmpty
            || Int(processing.trimmed) != nil || !resultNotes.trimmed.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    labeledField("Brand / line", text: $brand)
                    labeledField("Developer (e.g. 20 vol)", text: $developer)
                    labeledField("Ratio (e.g. 1:1.5)", text: $ratio)
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Processing (min)")
                        TextField("Processing (min)", text: $processing)
                            .keyboardType(.numberPad)
                            .chartFieldBackground()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Result / notes (encrypted)")
                        TextEditor(text: $resultNotes)
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .chartFieldBackground()
                    }
                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Add formula")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Add formula") { Task { await save() } }
                        .disabled(saving || !hasDetail)
                        .tint(BrandColor.accent)
                }
            }
            .tint(BrandColor.accent)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textSecondary)
    }

    private func labeledField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(title)
            TextField(title, text: text).chartFieldBackground()
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await session.client.proClients.addFormula(
                clientId: clientId,
                brand: brand.trimmedOrNil,
                developer: developer.trimmedOrNil,
                ratio: ratio.trimmedOrNil,
                processingTimeMinutes: Int(processing.trimmed),
                resultNotes: resultNotes.trimmedOrNil
            )
            onSaved()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save the formula. Try again."
        }
    }
}

// MARK: - Add consent

/// The proof methods a pro may CLAIM by hand, as (wire value, words).
///
/// 🔴 `CLIENT_TOKEN` is deliberately absent, and this list is file-scope so a
/// test can say so. It means "the platform witnessed this signature through a
/// link it sent", and since K15 the only writer of it is the signing route
/// behind the link — which also stamps `signatureTokenId`, the unique column
/// that proves a real link existed. `POST /pro/clients/{id}/consent` REFUSES it
/// with "Send the form to the client to record a link signature.", so offering
/// it here was a control the server could only ever say no to (K14-B: the
/// option had been lying since it shipped; K15 closed it on web, and this is the
/// device's half).
///
/// ⚠️ Reading a stored `CLIENT_TOKEN` is a different question and stays — a
/// record signed through a real link renders its own honest label.
let proConsentProofMethodOptions: [(value: String, label: String)] = [
    ("IN_PERSON", "In person"),
    ("PAPER_ON_FILE", "Paper on file"),
]

/// The consent kinds, as (wire value, words) — the ONE place these three labels
/// are spelled. They were previously written twice: inline `Text().tag()` rows
/// in this sheet's picker, and a private `switch` in the record card. Two copies
/// of a label table is one drift away from a card and a picker disagreeing about
/// what a record IS ([[drifted-duplicate-is-a-bug-report]]), and inline picker
/// rows are untestable — the reason K14's dead proof method survived to K17-A.
let proConsentKindOptions: [(value: String, label: String)] = [
    ("GENERAL_CONSENT", "General consent"),
    ("SERVICE_WAIVER", "Service waiver"),
    ("PATCH_TEST", "Patch test"),
]

/// A consent kind in words. An unrecognised value prints readably rather than
/// disappearing: this labels a record that already EXISTS, and a stored kind
/// this build doesn't know is still a record the pro must be able to see.
func proConsentKindLabel(_ kind: String) -> String {
    proConsentKindOptions.first { $0.value == kind }?.label
        ?? kind.replacingOccurrences(of: "_", with: " ").capitalized
}

/// POST /pro/clients/{id}/consent — a consent / waiver / patch-test record. The
/// patch-test result + validity apply only to PATCH_TEST; notes are encrypted.
struct ProAddConsentSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let clientId: String
    /// K14 — the pro's ACTIVE forms, from the technical record this sheet was
    /// opened over. Empty is a legitimate answer (a pro who has authored no
    /// forms), and the sheet simply offers no form to pin.
    var consentForms: [ProConsentFormOption.Display] = []
    var onSaved: () -> Void

    @State private var kind = "GENERAL_CONSENT"
    @State private var serviceScope = ""
    @State private var proofMethod = "" // "" = none
    @State private var hasSignedAt = false
    @State private var signedAt = Date()
    @State private var patchResult = "" // "" = none
    @State private var hasValidUntil = false
    @State private var validUntil = Date()
    @State private var notes = ""
    @State private var formVersionId = "" // "" = pin no form
    @State private var saving = false
    @State private var error: String?

    private var isPatch: Bool { kind == "PATCH_TEST" }

    /// 🔴 Only the forms whose kind MATCHES the record being written. The route
    /// 400s a mismatch ("That form is for a different kind of consent."), and it
    /// is right to: a record labelled PATCH_TEST pointing at a colour waiver's
    /// words reads as proof of something it isn't. Offering the choice and
    /// letting the server refuse it would be a control that can only fail
    /// ([[offered-option-must-be-an-accepted-write]]).
    private var formsForKind: [ProConsentFormOption.Display] {
        consentForms.filter { $0.kind.rawValue == kind }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Kind")
                        Picker("Kind", selection: $kind) {
                            ForEach(proConsentKindOptions, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(BrandColor.accent)
                        .onChange(of: kind) { _, _ in
                            // 🔴 The picker below re-filters on kind, but the
                            // SELECTION is state — a form pinned under the old
                            // kind would survive out of sight and post a
                            // mismatch the route 400s.
                            formVersionId = ""
                        }
                    }

                    // K14 — pin this record to the exact text the client was
                    // shown. Optional by design: a pro recording a paper waiver
                    // they hold has nothing to point at, and that record must
                    // still be writable.
                    if !formsForKind.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("Form signed")
                            Picker("Form signed", selection: $formVersionId) {
                                Text("No form — free-text record").tag("")
                                ForEach(formsForKind) { form in
                                    Text(form.label).tag(form.versionId ?? "")
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(BrandColor.accent)
                            Text("Pins this record to that version's exact wording. What you pin is stored as it reads today and never rewritten.")
                                .font(BrandFont.body(11))
                                .foregroundStyle(BrandColor.textMuted)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Service scope (e.g. color)")
                        TextField("Service scope", text: $serviceScope).chartFieldBackground()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Proof method")
                        Picker("Proof method", selection: $proofMethod) {
                            Text("Proof method…").tag("")
                            ForEach(proConsentProofMethodOptions, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(BrandColor.accent)
                    }

                    Toggle(isOn: $hasSignedAt) {
                        Text("Record signed date").font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                    }
                    .tint(BrandColor.accent)
                    if hasSignedAt {
                        DatePicker("Signed", selection: $signedAt, displayedComponents: .date)
                            .font(BrandFont.body(13)).tint(BrandColor.accent)
                    }

                    if isPatch {
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("Patch test result")
                            Picker("Result", selection: $patchResult) {
                                Text("Result…").tag("")
                                Text("Pass").tag("PASS")
                                Text("Fail").tag("FAIL")
                                Text("Inconclusive").tag("INCONCLUSIVE")
                            }
                            .pickerStyle(.segmented)
                        }
                        Toggle(isOn: $hasValidUntil) {
                            Text("Valid until").font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                        }
                        .tint(BrandColor.accent)
                        if hasValidUntil {
                            DatePicker("Valid until", selection: $validUntil, displayedComponents: .date)
                                .font(BrandFont.body(13)).tint(BrandColor.accent)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        fieldLabel("Notes (encrypted)")
                        TextEditor(text: $notes)
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .chartFieldBackground()
                    }

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Add record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Add record") { Task { await save() } }
                        .disabled(saving)
                        .tint(BrandColor.accent)
                }
            }
            .tint(BrandColor.accent)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textSecondary)
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await session.client.proClients.addConsent(
                clientId: clientId,
                kind: kind,
                serviceScope: serviceScope.trimmedOrNil,
                proofMethod: proofMethod.isEmpty ? nil : proofMethod,
                proofRef: nil,
                signedAt: hasSignedAt ? isoDay(signedAt) : nil,
                notes: notes.trimmedOrNil,
                patchTestResult: isPatch && !patchResult.isEmpty ? patchResult : nil,
                validUntil: isPatch && hasValidUntil ? isoDay(validUntil) : nil,
                formVersionId: formVersionId.isEmpty ? nil : formVersionId
            )
            onSaved()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t save the record. Try again."
        }
    }
}

// MARK: - Edit photo release

/// PATCH /pro/clients/{id}/photo-release — the client's standing release decision.
struct ProEditPhotoReleaseSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let clientId: String
    var onSaved: () -> Void

    @State private var status: String
    @State private var saving = false
    @State private var error: String?

    private let options = ["NOT_SET", "GRANTED", "DECLINED"]

    init(clientId: String, current: String, onSaved: @escaping () -> Void) {
        self.clientId = clientId
        self.onSaved = onSaved
        _status = State(initialValue: options.contains(current) ? current : "NOT_SET")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Photo release", selection: $status) {
                        ForEach(options, id: \.self) { Text(label($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Text("The client's standing release decision. Public sharing still requires the client to promote a photo via a review — this flag does not publish anything on its own.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)

                    if let error {
                        Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Photo release")
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

    private func label(_ value: String) -> String {
        switch value {
        case "GRANTED": return "Granted"
        case "DECLINED": return "Declined"
        default: return "Not set"
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            try await session.client.proClients.updatePhotoRelease(clientId: clientId, status: status)
            onSaved()
            dismiss()
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t update the photo release. Try again."
        }
    }
}
