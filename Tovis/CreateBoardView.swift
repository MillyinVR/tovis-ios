// Native "New board" flow — the counterpart to the web CreateBoardForm
// (app/client/(gated)/boards/_components/CreateBoardForm.tsx). Presented as a
// sheet from the "Me" tab's BOARDS grid. Captures a board's name, purpose (type),
// shareability, and — for bridal/prom — an optional event date, then POSTs to
// /api/v1/boards via BoardsService.
//
// The per-type personalization chip questions + self-profile write-through (spec
// §7) are intentionally left to a follow-on; this covers the board's identity,
// purpose, and sharing.
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

    @State private var saving = false
    @State private var errorText: String?

    private var wantsEventDate: Bool {
        BoardCatalog.types.first { $0.value == selectedType }?.wantsEventDate ?? false
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
                        selectedType = option.value
                        // The event date belongs to the type that asked for it.
                        if !wantsEventDate { hasEventDate = false }
                    }
                }
            }
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
        return Self.ymd.string(from: eventDate)
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
                eventDate: eventDateString
            )
            onCreated(created)
            dismiss()
        } catch let error as APIError {
            errorText = error.userMessage
        } catch {
            errorText = "Couldn’t create the board."
        }
    }

    /// `YYYY-MM-DD` in UTC — the calendar-date format the board event date uses
    /// (matches ProVerification's license-expiry / the client birthday encoding).
    private static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
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
