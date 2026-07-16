// Native "New board" flow — the counterpart to the web CreateBoardForm
// (app/client/(gated)/boards/_components/CreateBoardForm.tsx). Presented as a
// sheet from the "Me" tab's BOARDS grid. Captures a board's name, purpose (type),
// shareability, — for bridal/prom — an optional event date, and (spec §7.3) the
// per-type personalization chip questions with the optional self-profile
// write-through, then POSTs to /api/v1/boards via BoardsService.
import SwiftUI
import TovisKit

struct CreateBoardView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Called with the created board so the host can refresh (and optionally open it).
    let onCreated: (Board) -> Void

    private static let nameMax = 120

    @State private var name = ""
    @State private var selectedType = "GENERAL"
    @State private var isShared = false
    @State private var hasEventDate = false
    @State private var eventDate = Date()
    /// Per-type chip answers (question key → chosen option value, spec §7.3).
    /// Cleared whenever the board type changes (answers are type-specific).
    @State private var answers: [String: String] = [:]
    /// The "save these details to my profile" opt-in (only meaningful when a
    /// person-describing question is answered).
    @State private var writeThrough = false

    @State private var saving = false
    @State private var errorText: String?

    private var wantsEventDate: Bool {
        BoardCatalog.types.first { $0.value == selectedType }?.wantsEventDate ?? false
    }

    private var questions: [BoardQuestion] {
        BoardCatalog.questions(for: selectedType)
    }

    /// True once a person-describing question is answered — mirrors the web's
    /// `hasWriteThroughAnswers`, which gates the write-through opt-in.
    private var hasWriteThroughAnswers: Bool {
        answers.keys.contains { BoardCatalog.writeThroughAnswerKeys.contains($0) }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let errorText {
                        Text(errorText)
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.ember)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(BrandColor.ember.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    nameField
                    typeSection
                    if wantsEventDate { eventDateSection }
                    if !questions.isEmpty { questionsSection }
                    if hasWriteThroughAnswers { writeThroughSection }
                    visibilitySection

                    SignupPrimaryButton(
                        title: "Create board",
                        isLoading: saving,
                        isDisabled: !canSave
                    ) {
                        Task { await save() }
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("New board")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(BrandColor.textSecondary)
                        .disabled(saving)
                }
            }
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            SignupFieldLabel("Board name")
            TextField("", text: $name, prompt: Text("Spring hair inspo").foregroundStyle(BrandColor.textMuted))
                .font(BrandFont.body(16))
                .foregroundStyle(BrandColor.textPrimary)
                .autocorrectionDisabled(false)
                .padding(.horizontal, 16).padding(.vertical, 15)
                .background(BrandColor.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
                )
                .onChange(of: name) { _, newValue in
                    if newValue.count > Self.nameMax { name = String(newValue.prefix(Self.nameMax)) }
                }
        }
    }

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SignupFieldLabel("What’s this board for?")
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(BoardCatalog.types) { option in
                    BoardChip(label: option.label, selected: selectedType == option.value) {
                        let changed = selectedType != option.value
                        selectedType = option.value
                        // The event date + chip answers belong to the type that
                        // asked for them — a type change wipes both (web parity).
                        if !wantsEventDate { hasEventDate = false }
                        if changed {
                            answers = [:]
                            writeThrough = false
                        }
                    }
                }
            }
        }
    }

    /// The per-type creation-context questions (spec §7.3) — single-select chips,
    /// tap again to clear. All optional.
    private var questionsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        SignupFieldLabel(question.label)
                        Text("optional")
                            .font(BrandFont.body(11))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(question.options) { option in
                            BoardChip(label: option.label, selected: answers[question.key] == option.value) {
                                toggleAnswer(question.key, option.value)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The optional self-profile write-through opt-in — shown only once a
    /// person-describing question is answered (web `hasWriteThroughAnswers`).
    private var writeThroughSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            BoardChip(label: "Save these details to my profile", selected: writeThrough) {
                writeThrough.toggle()
            }
            Text("Answers about you (like hair length or skin type) can be saved to your profile so every board gets better matches. Optional — you can edit or clear them anytime in settings.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    /// Single-select: a second tap on the chosen option clears it (web `toggleAnswer`).
    private func toggleAnswer(_ key: String, _ value: String) {
        if answers[key] == value {
            answers[key] = nil
        } else {
            answers[key] = value
        }
    }

    private var eventDateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SignupFieldLabel(selectedType == "BRIDAL" ? "Wedding date" : "Prom date")
                Spacer()
                Toggle("", isOn: $hasEventDate)
                    .labelsHidden()
                    .tint(BrandColor.accent)
            }
            if hasEventDate {
                DatePicker("", selection: $eventDate, displayedComponents: [.date])
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .tint(BrandColor.accent)
                Text("We’ll count down with you. You can change or clear it anytime.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
    }

    private var visibilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shared board")
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(isShared
                        ? "Gets a public link you can send anyone."
                        : "Private — just for you. You can change this anytime.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                Spacer(minLength: 0)
                Toggle("", isOn: $isShared)
                    .labelsHidden()
                    .tint(BrandColor.accent)
            }
        }
    }

    // MARK: - Save

    private var eventDateString: String? {
        guard wantsEventDate, hasEventDate else { return nil }
        return BoardEventDate.ymd(from: eventDate)
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !saving else { return }
        saving = true
        errorText = nil
        defer { saving = false }
        do {
            let created = try await session.client.boards.create(
                name: trimmed,
                visibility: isShared ? "SHARED" : "PRIVATE",
                type: selectedType,
                eventDate: eventDateString,
                answers: answers.isEmpty ? nil : answers,
                // Only opt in when a person-describing answer is actually present.
                writeThroughSelfProfile: hasWriteThroughAnswers && writeThrough
            )
            onCreated(created)
            dismiss()
        } catch let error as APIError {
            errorText = error.userMessage
        } catch {
            errorText = "Couldn’t create the board."
        }
    }
}

/// A single-select chip for the board-type row. Matches the accent-tinted pill
/// used by the self-profile / signup selectors.
private struct BoardChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(selected ? BrandColor.textPrimary : BrandColor.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(selected ? BrandColor.accent.opacity(0.14) : BrandColor.bgSurface)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        selected ? BrandColor.accent.opacity(0.4) : BrandColor.textMuted.opacity(0.18),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
