// Add / edit a tracked expense — the sheet behind the Finance tab's "Add
// expense" button and each row's edit action. Posts to /pro/finance/expenses
// (POST) or /{id} (PATCH); on success it calls `onSaved` so the Finance screen
// reloads the month (keeping totals consistent, like the web).
import SwiftUI
import TovisKit

struct ProExpenseFormView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let categories: [ProFinanceResponse.CategoryInfo]
    let editing: ProFinanceResponse.ExpenseItem?
    /// The pro's timezone (from the finance response). The date picker + the
    /// submitted "YYYY-MM-DD" resolve in THIS zone, not the device's, so an
    /// expense added on a month-end evening files under the pro's calendar day.
    let timeZone: String
    /// Current IRS mileage rate (cents/mile) for the live deduction preview.
    let mileageRateCents: Double
    /// When set, the form CONFIRMS this receipt inbox item into an expense
    /// (instead of creating a fresh one), prefilled from the seed values.
    var confirmReceiptId: String? = nil
    var seedAmount: String? = nil
    var seedLabel: String? = nil
    var seedDate: String? = nil
    let onSaved: () -> Void

    private var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }
    private var isReview: Bool { confirmReceiptId != nil }

    @State private var category = ""
    @State private var amount = ""
    @State private var miles = ""
    @State private var label = ""
    @State private var date = Date()
    @State private var notes = ""
    @State private var submitting = false
    @State private var errorText: String?

    private var isMileage: Bool { category == "MILEAGE" }

    private var milesValue: Double? {
        let n = Double(miles.trimmingCharacters(in: .whitespaces))
        return (n ?? 0) > 0 ? n : nil
    }

    /// Live-computed deduction (cents) for the entered miles.
    private var mileagePreviewCents: Int? {
        guard let m = milesValue else { return nil }
        return Int((m * mileageRateCents).rounded())
    }

    private var canSubmit: Bool {
        guard !category.isEmpty, !label.trimmingCharacters(in: .whitespaces).isEmpty
        else { return false }
        return isMileage
            ? milesValue != nil
            : !amount.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Category") {
                        Picker("Category", selection: $category) {
                            ForEach(categories) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(BrandColor.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if isMileage {
                        field("Miles") {
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("e.g. 45", text: $miles)
                                    .keyboardType(.decimalPad)
                                    .textFieldStyle(.plain)
                                Text(mileageDeductionHint)
                                    .font(BrandFont.body(11))
                                    .foregroundStyle(BrandColor.textMuted)
                            }
                        }
                    } else {
                        field("Amount") {
                            TextField("50 or 49.99", text: $amount)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.plain)
                        }
                    }

                    field("Description") {
                        TextField("e.g. CosmoProf order", text: $label)
                            .textFieldStyle(.plain)
                    }

                    field("Date") {
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                            .tint(BrandColor.accent)
                            .environment(\.timeZone, zone)
                    }

                    field("Notes (optional)") {
                        TextField("Anything to remember", text: $notes)
                            .textFieldStyle(.plain)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle(isReview ? "Review receipt" : editing == nil ? "Add expense" : "Edit expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isReview ? "Add" : editing == nil ? "Add" : "Save") { Task { await save() } }
                        .tint(BrandColor.accent)
                        .disabled(!canSubmit || submitting)
                }
            }
        }
        .onAppear(perform: seed)
    }

    private func field<Content: View>(
        _ title: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(BrandFont.mono(10))
                .tracking(0.8)
                .foregroundStyle(BrandColor.textMuted)
            content()
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textPrimary)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BrandColor.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(BrandColor.textMuted.opacity(0.16), lineWidth: 1)
                )
        }
    }

    private var mileageRateString: String { String(format: "%g", mileageRateCents) }

    private var mileageDeductionHint: String {
        let rate = "\(mileageRateString)¢/mi"
        if let cents = mileagePreviewCents {
            return "= " + String(format: "$%.2f", Double(cents) / 100) + " deduction at " + rate
        }
        return "Business miles only at " + rate
    }

    private func seed() {
        if let editing {
            category = editing.category
            if let loggedMiles = editing.mileageMiles {
                miles = String(format: "%g", loggedMiles)
            } else {
                amount = String(format: "%.2f", Double(editing.amountCents) / 100)
            }
            label = editing.label
            notes = editing.notes ?? ""
            date = parseDate(editing.spentAtIso) ?? Date()
        } else {
            category = categories.first?.id ?? ""
            if let seedAmount { amount = seedAmount }
            if let seedLabel { label = seedLabel }
            if let seedDate, let seeded = ymd.date(from: seedDate) {
                date = seeded
            } else {
                date = Date()
            }
        }
    }

    private func save() async {
        guard canSubmit, !submitting else { return }
        submitting = true
        errorText = nil

        let notesValue = notes.trimmedOrNil
        let request = isMileage
            ? ProExpenseWriteRequest(
                category: category,
                miles: miles.trimmingCharacters(in: .whitespaces),
                label: label.trimmingCharacters(in: .whitespaces),
                date: formatDate(date),
                notes: notesValue
            )
            : ProExpenseWriteRequest(
                category: category,
                amount: amount.trimmingCharacters(in: .whitespaces),
                label: label.trimmingCharacters(in: .whitespaces),
                date: formatDate(date),
                notes: notesValue
            )

        do {
            if let confirmReceiptId {
                try await session.client.proFinance.confirmReceipt(id: confirmReceiptId, request)
            } else if let editing {
                try await session.client.proFinance.updateExpense(id: editing.id, request)
            } else {
                try await session.client.proFinance.createExpense(request)
            }
            onSaved()
            dismiss()
        } catch let error as APIError {
            errorText = error.userMessage
            submitting = false
        } catch {
            errorText = "Couldn’t save this expense."
            submitting = false
        }
    }

    // Formats/parses "YYYY-MM-DD" in the PRO's timezone (not the device's).
    private var ymd: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = zone
        return formatter
    }

    private func formatDate(_ date: Date) -> String {
        ymd.string(from: date)
    }

    /// spentAtIso is "2026-04-03T07:00:00.000Z" — seed the picker from its date part.
    private func parseDate(_ iso: String) -> Date? {
        ymd.date(from: String(iso.prefix(10)))
    }
}
