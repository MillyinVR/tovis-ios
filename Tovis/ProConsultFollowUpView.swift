import SwiftUI
import TovisKit

// C2-4 — "Ask a follow-up", on the pro's Brief.
//
// The pro types one question in plain words and two to six answers the client
// can tap. It lands in the client's consult thread as a card with the pro's
// name on it (web and iOS alike — same card, same answer route as the model's
// follow-ups), and the client gets a gentle notification. Nothing here is
// clever: no translation yet, no free-text answers, no photo asks. Those are
// later slices, and this control says nothing that promises them.
//
// Mirrors tovis-app `app/pro/_components/consult/ProConsultAskFollowUp.tsx`:
// the list of what she asked (priority · answered/waiting), the open-cap
// message, then the form. The words are `ProConsultFollowUpCopy` in TovisKit,
// a line-for-line twin of `lib/brand/consultProFollowUpCopy.ts`.

/// The section on the Brief. Takes the questions and a closure rather than the
/// whole screen's state, the same shape the render tests need
/// (`ConsultParityRenderTests`) — a leaf that holds the session cannot be
/// rendered to a PNG without one.
struct ProConsultFollowUpSection: View {
    let consultId: String
    let questions: [ProConsultFollowUp]
    let busy: Bool
    let onAsked: () -> Void
    @State private var asking = false

    private var openCount: Int { questions.filter(\.isOpen).count }
    private var atOpenCap: Bool { openCount >= ProConsultFollowUpLimits.maxOpen }
    private var atTotalCap: Bool { questions.count >= ProConsultFollowUpLimits.maxPerConsult }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ProConsultFollowUpCopy.title).font(BrandFont.body(18, .semibold))
            Text(ProConsultFollowUpCopy.intro)
                .foregroundStyle(BrandColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(ProConsultFollowUpCopy.askedList)
                .font(BrandFont.body(11, .bold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(BrandColor.textMuted)
            if questions.isEmpty {
                Text(ProConsultFollowUpCopy.none).foregroundStyle(BrandColor.textSecondary)
            }
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.text)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 0) {
                        Text(ProConsultFollowUpCopy.priorityTitle(question.priority))
                        Text(" · ")
                        if let label = question.selectedLabel {
                            Text("\(ProConsultFollowUpCopy.answered): \(label)")
                                .fontWeight(.semibold)
                                .foregroundStyle(BrandColor.textPrimary)
                        } else {
                            Text(ProConsultFollowUpCopy.waiting)
                        }
                    }
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(BrandColor.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier(
                    question.isOpen ? "pro-consult-follow-up-open" : "pro-consult-follow-up-answered"
                )
            }

            if atOpenCap {
                Text(ProConsultFollowUpCopy.openLimit(ProConsultFollowUpLimits.maxOpen))
                    .foregroundStyle(BrandColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if atTotalCap {
                Text(ProConsultFollowUpCopy.totalLimit).foregroundStyle(BrandColor.textSecondary)
            } else {
                Button(ProConsultFollowUpCopy.title) { asking = true }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    .accessibilityIdentifier("pro-consult-ask-follow-up")
            }
        }
        .accessibilityIdentifier("pro-consult-follow-ups")
        .sheet(isPresented: $asking) {
            ProConsultAskFollowUpSheet(consultId: consultId) { onAsked() }
        }
    }
}

/// The form. One question, two to six answers, a priority, Send.
///
/// The draft's rules live in TovisKit (`ProConsultFollowUpDraft.normalized()`)
/// and are the parser's rules; the SERVER still decides — a refusal it makes
/// (open cap reached meanwhile, appointment started, no Brief) is shown in its
/// own words, the way the web control shows `payload.error`.
struct ProConsultAskFollowUpSheet: View {
    /// One answer row. Rows carry their OWN identity so a TextField bound to
    /// one survives the row above it being removed — binding by array index
    /// is the out-of-range crash SwiftUI is known for.
    private struct OptionRow: Identifiable {
        let id = UUID()
        var text = ""
    }

    let consultId: String
    let onAsked: () -> Void
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var priority = ProConsultFollowUpPriority.helpfulForPrep
    @State private var rows: [OptionRow] = [OptionRow(), OptionRow()]
    @State private var busy = false
    @State private var error: String?

    private var draft: ProConsultFollowUpDraft {
        ProConsultFollowUpDraft(priority: priority, text: text, options: rows.map(\.text))
    }
    private var canSubmit: Bool { !busy && draft.normalized() != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(ProConsultFollowUpCopy.textPlaceholder, text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .disabled(busy)
                        .accessibilityIdentifier("pro-consult-follow-up-text")
                    Text(ProConsultFollowUpCopy.textHint)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                } header: {
                    Text(ProConsultFollowUpCopy.textLabel)
                }

                Section {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HStack {
                            TextField(
                                ProConsultFollowUpCopy.optionPlaceholder(index),
                                text: Binding(
                                    get: { rows.first { $0.id == row.id }?.text ?? "" },
                                    set: { value in
                                        if let at = rows.firstIndex(where: { $0.id == row.id }) { rows[at].text = value }
                                    }
                                )
                            )
                            .disabled(busy)
                            .accessibilityIdentifier("pro-consult-follow-up-option-\(index)")
                            if rows.count > ProConsultFollowUpLimits.minOptions {
                                Button(ProConsultFollowUpCopy.removeOption) {
                                    rows.removeAll { $0.id == row.id }
                                }
                                .font(BrandFont.body(12, .semibold))
                                .foregroundStyle(BrandColor.textSecondary)
                                .disabled(busy)
                            }
                        }
                    }
                    if rows.count < ProConsultFollowUpLimits.maxOptions {
                        Button(ProConsultFollowUpCopy.addOption) { rows.append(OptionRow()) }
                            .disabled(busy)
                            .accessibilityIdentifier("pro-consult-follow-up-add-option")
                    }
                    Text(ProConsultFollowUpCopy.optionsHint)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                } header: {
                    Text(ProConsultFollowUpCopy.optionsLabel)
                }

                Section {
                    Picker(ProConsultFollowUpCopy.priorityLabel, selection: $priority) {
                        ForEach(ProConsultFollowUpPriority.askable, id: \.self) { priority in
                            Text(ProConsultFollowUpCopy.priorityTitle(priority)).tag(priority)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(busy)
                    Text(ProConsultFollowUpCopy.priorityHint(priority))
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                } header: {
                    Text(ProConsultFollowUpCopy.priorityLabel)
                }

                if let error {
                    Text(error)
                        .foregroundStyle(BrandColor.ember)
                        .accessibilityIdentifier("pro-consult-follow-up-error")
                }

                Button(busy ? ProConsultFollowUpCopy.sending : ProConsultFollowUpCopy.submit) {
                    Task { await send() }
                }
                .disabled(!canSubmit)
                .accessibilityIdentifier("pro-consult-follow-up-send")
            }
            .navigationTitle(ProConsultFollowUpCopy.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            }
        }
        .tint(BrandColor.accent)
    }

    private func send() async {
        guard let ask = draft.normalized() else { error = ProConsultFollowUpCopy.invalid; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            _ = try await ProConsultService(api: session.client.api).askFollowUp(id: consultId, ask)
            onAsked()
            dismiss()
        } catch let APIError.server(_, message, _) where message?.isEmpty == false {
            // The server's own sentence: the open cap, the total cap, "not
            // ready for a question yet", the closed window.
            error = message
        } catch {
            self.error = ProConsultFollowUpCopy.failed
        }
    }
}
