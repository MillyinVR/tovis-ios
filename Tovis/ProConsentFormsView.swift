// The pro's CONSENT FORM LIBRARY, native. Web parity: /pro/forms.
//
// The app has been able to USE consent forms since K14 — attach one to a
// client's technical record, list the unsigned ones in the session hub, text a
// signing link — and has never been able to WRITE one. K14 shipped the library
// with three write routes and no read route, so authoring lived entirely inside
// one web page. A pro who only had their phone could send a waiver and never
// create one.
//
// 🔴 The one idea this surface has to get across: there is no editing. Saving a
// change PUBLISHES a new version, and every record already signed keeps the
// words it was signed against. So the button says so, and a form that has been
// signed says how many times — that number is the reason the model works this
// way, and hiding it is what would make the behaviour feel like a bug.
//
// Reached from the Business list in the Profile tab, gated on
// `ProCapabilities.clientTechnicalRecord`: every route here 404s while the
// technical-record gate is off for this pro, and the row must not walk them into
// that. A 404 reaching this screen anyway (a capability read that raced a flag
// change) is shown as "not available", never as an empty library.
import SwiftUI
import TovisKit

struct ProConsentFormsView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded(ProConsentFormLibrary)
        /// The route 404'd — the technical-record gate is off for this pro.
        case unavailable
        case failed(String)
    }

    @State private var phase: Phase = .loading
    /// A write that was refused. Its own channel, separate from `phase`: a
    /// failed retire must not replace the library the pro is looking at.
    @State private var actionError: String?
    @State private var editing: ProConsentFormEditorTarget?
    /// The id of the form whose in-place action is in flight, for its spinner.
    @State private var busyFormId: String?

    private var library: ProConsentFormLibrary? {
        if case let .loaded(value) = phase { return value }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.vertical, 60)
                case .unavailable:
                    unavailableState
                case let .failed(message):
                    failedState(message)
                case let .loaded(value):
                    if let actionError {
                        BrandErrorBanner(message: actionError)
                    }
                    intro
                    yourForms(value)
                    templates(value)
                }
            }
            .padding(20)
        }
        .cappedWidth(AdaptiveWidth.reading)
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Consent forms")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .tint(BrandColor.accent)
        .toolbar {
            if let limits = library?.limits {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = .newForm(limits: limits)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New form")
                }
            }
        }
        .task { if case .loading = phase { await load() } }
        .sheet(item: $editing) { target in
            ProConsentFormEditorSheet(target: target, onSaved: { Task { await load() } })
        }
    }

    // MARK: - Sections

    private var intro: some View {
        Text("The waivers and consent text you put in front of clients. Editing a form publishes a new version — records already signed keep the exact words they were signed against, so an old record never changes when you update the form.")
            .font(BrandFont.body(13))
            .foregroundStyle(BrandColor.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func yourForms(_ value: ProConsentFormLibrary) -> some View {
        BrandSection(title: "Your forms") {
            if value.forms.isEmpty {
                BrandSurface {
                    Text("No forms yet. Write your own, or add one of the templates below.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(value.forms) { form in
                        ProConsentFormCard(
                            form: form,
                            isBusy: busyFormId == form.id,
                            actionsDisabled: busyFormId != nil,
                            onToggleActive: {
                                Task { await setActive(form, isActive: !form.isActive) }
                            },
                            onEditText: {
                                editing = .newVersion(form: form, limits: value.limits)
                            }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func templates(_ value: ProConsentFormLibrary) -> some View {
        BrandSection(title: "Templates") {
            if value.templates.isEmpty {
                BrandSurface {
                    Text("No templates are available yet.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(value.templates) { template in
                        ProConsentTemplateCard(
                            template: template,
                            isBusy: busyFormId == template.form.id,
                            actionsDisabled: busyFormId != nil,
                            onAdopt: { Task { await adopt(template) } }
                        )
                    }
                }
            }
        }
    }

    // MARK: - States

    private var unavailableState: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text("Consent forms aren’t available on this account yet")
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("They arrive with the client technical record.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private func failedState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }
                .buttonStyle(.plain)
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(BrandColor.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Actions

    private func load() async {
        actionError = nil
        do {
            phase = .loaded(try await session.client.proConsentForms.library())
        } catch let error as APIError {
            // 404 is the gate, not a fault — an empty library is a 200 with
            // empty arrays, and the two must never be shown the same way.
            if case let .server(status, _, _) = error, status == 404 {
                phase = .unavailable
            } else {
                phase = .failed(error.userMessage)
            }
        } catch {
            phase = .failed("Couldn’t load your forms.")
        }
    }

    private func setActive(_ form: ProConsentFormLibraryItem, isActive: Bool) async {
        guard busyFormId == nil else { return }
        busyFormId = form.id
        actionError = nil
        defer { busyFormId = nil }
        do {
            try await session.client.proConsentForms.setActive(
                formId: form.id, isActive: isActive
            )
            await load()
        } catch let error as APIError {
            actionError = error.userMessage
        } catch {
            actionError = isActive
                ? "Couldn’t put that form back in use."
                : "Couldn’t retire that form."
        }
    }

    private func adopt(_ template: ProConsentFormTemplate) async {
        guard busyFormId == nil else { return }
        busyFormId = template.form.id
        actionError = nil
        defer { busyFormId = nil }
        do {
            try await session.client.proConsentForms.adoptTemplate(templateId: template.form.id)
            await load()
        } catch let error as APIError {
            actionError = error.userMessage
        } catch {
            actionError = "Couldn’t add that template."
        }
    }
}

// MARK: - Cards

/// "Service waiver · Written by you · v2 of 3".
///
/// 🔴 The provenance half (`originLabel`) is printed exactly as the server
/// composed it, never re-derived. The rule that separates a platform template
/// ADOPTED unchanged from one the pro EDITED lives in one place on the server,
/// and a second spelling of it is how an edited form borrows the platform's
/// authority.
func proConsentFormSubtitle(_ form: ProConsentFormLibraryItem) -> String {
    var parts = [proConsentKindLabel(form.kind), form.originLabel]
    if let current = form.currentVersion {
        parts.append("v\(current.version) of \(form.versionCount)")
    } else {
        parts.append("no text published")
    }
    return parts.joined(separator: " · ")
}

func proConsentTemplateSubtitle(_ form: ProConsentFormLibraryItem) -> String {
    var text = proConsentKindLabel(form.kind)
    if let current = form.currentVersion { text += " · v\(current.version)" }
    return text
}

/// The sentence that makes append-only versioning legible at the moment it
/// matters — inside the editor, where "saving" is about to do something other
/// than what the word usually means.
///
/// A free function so the copy can be read by a test: it is the one piece of
/// wording on this surface that carries a RULE rather than a label, and web
/// carries the same three arms.
func proConsentPublishNote(for form: ProConsentFormLibraryItem?) -> String {
    guard let form else {
        return "This publishes v1. Editing it later publishes a new version — nothing already signed ever changes."
    }
    let next = (form.currentVersion?.version ?? 0) + 1
    switch form.signatureCount {
    case 0:
        return "Saving publishes v\(next). Nothing has been signed against this form yet."
    case 1:
        return "Saving publishes v\(next). The record already signed against this form keeps its own version."
    default:
        return "Saving publishes v\(next). The \(form.signatureCount) records already signed against this form keep their own versions."
    }
}

/// One of the pro's own forms.
///
/// Standalone (data in, closures out) rather than a method on the screen: it is
/// the piece worth LOOKING at, and a card that needs a whole session to render
/// is a card nobody can put in front of their eyes without running the app.
struct ProConsentFormCard: View {
    let form: ProConsentFormLibraryItem
    var isBusy: Bool = false
    var actionsDisabled: Bool = false
    var onToggleActive: () -> Void = {}
    var onEditText: () -> Void = {}

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(form.currentVersion?.title ?? "Untitled form")
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(proConsentFormSubtitle(form))
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                FlowLayout(spacing: 8) {
                    // The number that explains why editing publishes instead of
                    // overwriting. Absent when nothing has been signed — a "0
                    // signed" pill would be noise on every new form.
                    if form.signatureCount > 0 {
                        BrandPill(text: "\(form.signatureCount) signed", tint: BrandColor.accent)
                    }
                    BrandPill(
                        text: form.isActive ? "In use" : "Retired",
                        tint: form.isActive ? BrandColor.emerald : BrandColor.textMuted
                    )
                }

                if let current = form.currentVersion {
                    DisclosureGroup("Current text") {
                        Text(current.body)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                    .font(BrandFont.body(12, .semibold))
                    .tint(BrandColor.textSecondary)
                }

                HStack(spacing: 10) {
                    Button(form.isActive ? "Retire" : "Put back in use", action: onToggleActive)
                        .buttonStyle(.plain)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.textSecondary)

                    Spacer(minLength: 0)

                    if isBusy { ProgressView().tint(BrandColor.accent) }

                    // "Edit text", not "Edit": what it opens publishes a new
                    // version, and the sheet says so before it lands.
                    Button("Edit text", action: onEditText)
                        .buttonStyle(.plain)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.accent)
                }
                .disabled(actionsDisabled)
            }
        }
    }
}

/// A platform template on offer.
struct ProConsentTemplateCard: View {
    let template: ProConsentFormTemplate
    var isBusy: Bool = false
    var actionsDisabled: Bool = false
    var onAdopt: () -> Void = {}

    private var form: ProConsentFormLibraryItem { template.form }

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(form.currentVersion?.title ?? "Untitled template")
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(proConsentTemplateSubtitle(form))
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                    Spacer(minLength: 0)

                    // 🔴 No "Add" on a template already adopted: the create
                    // route 409s a second adoption, so offering it would be a
                    // control that can only fail.
                    if template.adopted {
                        BrandPill(text: "Added")
                    } else if isBusy {
                        ProgressView().tint(BrandColor.accent)
                    } else {
                        Button("Add to my forms", action: onAdopt)
                            .buttonStyle(.plain)
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.accent)
                            .disabled(actionsDisabled)
                    }
                }

                if let current = form.currentVersion {
                    DisclosureGroup("Read the text") {
                        Text(current.body)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                    .font(BrandFont.body(12, .semibold))
                    .tint(BrandColor.textSecondary)
                }
            }
        }
    }
}

// MARK: - Editor

/// What the editor sheet is for. Both arms carry the server's `limits` rather
/// than reading a constant, so the field stops the pro exactly where
/// `parseConsentFormText` would refuse them.
enum ProConsentFormEditorTarget: Identifiable {
    case newForm(limits: ProConsentFormLimits)
    case newVersion(form: ProConsentFormLibraryItem, limits: ProConsentFormLimits)

    var id: String {
        switch self {
        case .newForm: return "new"
        case let .newVersion(form, _): return form.id
        }
    }

    var limits: ProConsentFormLimits {
        switch self {
        case let .newForm(limits): return limits
        case let .newVersion(_, limits): return limits
        }
    }
}

/// Write a new form, or publish the next version of one.
///
/// 🔴 One sheet for both because they are the same act with a different
/// destination — and because the sentence that matters ("saving publishes v3,
/// the 2 records already signed keep their own versions") has to be in front of
/// the pro in the editing case, where it is a surprise, not just in the docs.
struct ProConsentFormEditorSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let target: ProConsentFormEditorTarget
    var onSaved: () -> Void

    @State private var kind = "SERVICE_WAIVER"
    @State private var title = ""
    @State private var body_ = ""
    @State private var saving = false
    @State private var error: String?

    private var isNewForm: Bool {
        if case .newForm = target { return true }
        return false
    }

    private var existing: ProConsentFormLibraryItem? {
        if case let .newVersion(form, _) = target { return form }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if isNewForm { kindPicker }

                    VStack(alignment: .leading, spacing: 6) {
                        SignupFieldLabel("Form title")
                        BrandField(
                            placeholder: "e.g. Corrective colour waiver",
                            text: $title,
                            isSecure: false
                        )
                        counter(title.count, max: target.limits.titleMax)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        SignupFieldLabel("The text the client agrees to")
                        TextEditor(text: $body_)
                            .font(BrandFont.body(14))
                            .foregroundStyle(BrandColor.textPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 220)
                            .padding(10)
                            .background(BrandColor.bgSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
                            )
                        counter(body_.count, max: target.limits.bodyMax)
                    }

                    Text(publishNote)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    if let error {
                        BrandErrorBanner(message: error)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle(isNewForm ? "New form" : "Edit text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveLabel) { Task { await save() } }
                        .disabled(saving || !isSendable)
                }
            }
            .tint(BrandColor.accent)
        }
        .onAppear {
            guard let current = existing?.currentVersion else { return }
            title = current.title
            body_ = current.body
        }
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            SignupFieldLabel("Kind")
            Menu {
                ForEach(proConsentKindOptions, id: \.value) { option in
                    Button(option.label) { kind = option.value }
                }
            } label: {
                SignupPickerChrome(text: proConsentKindLabel(kind), muted: false)
            }
        }
    }

    private func counter(_ count: Int, max: Int) -> some View {
        Text("\(count) / \(max)")
            .font(BrandFont.mono(11))
            .foregroundStyle(count > max ? BrandColor.ember : BrandColor.textMuted)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var publishNote: String { proConsentPublishNote(for: existing) }

    private var saveLabel: String {
        if saving { return "Saving…" }
        return isNewForm ? "Publish v1" : "Publish"
    }

    /// Local refusals only — length and emptiness, using the SERVER's limits.
    /// Everything else (canonicalization, "nothing changed") is the server's
    /// call and arrives as its own sentence.
    private var isSendable: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.count <= target.limits.titleMax
            && body_.count <= target.limits.bodyMax
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        error = nil
        defer { saving = false }
        do {
            if let form = existing {
                try await session.client.proConsentForms.publishVersion(
                    formId: form.id, title: title, body: body_
                )
            } else {
                try await session.client.proConsentForms.create(
                    kind: kind, title: title, body: body_
                )
            }
            onSaved()
            dismiss()
        } catch let error as APIError {
            // The server's own sentence — "Nothing changed — this is already the
            // current text.", a length refusal, a kind it does not know. Printing
            // our own here is how a surface starts disagreeing with the rule.
            self.error = error.userMessage
        } catch {
            self.error = "Couldn’t save that form."
        }
    }
}
