import SwiftUI
import TovisKit

/// P7a-5 — "When clients can book", per service category, plus that category's
/// deposit.
///
/// Mounted inside the existing services screen (`ProOfferingsView`) rather than
/// on a screen of its own (Tori, 2026-09-07): a pro thinking about her colour
/// work is already here.
///
/// The web twin is `app/pro/services/CategoryBookingPolicyEditor.tsx`. Both read
/// and write the same endpoint and both show the SERVER's refusal sentence
/// verbatim — it names the setting that fixes the problem, which a local
/// "Couldn't save" would throw away.
struct ProCategoryBookingPolicySection: View {
    @Environment(SessionModel.self) private var session

    private enum Phase { case loading, loaded, failed(String) }
    @State private var phase: Phase = .loading
    @State private var categories: [ProCategoryBookingPolicy] = []
    @State private var accountDeposit: ProCategoryAccountDeposit?
    @State private var depositBlocker: String?
    @State private var busyId: String?
    @State private var actionError: String?
    /// Per-category draft amounts, keyed by category id. Committed on the radio
    /// tap or when the field loses focus — never on every keystroke, which would
    /// PATCH the money configuration once per digit.
    @State private var flatDrafts: [String: String] = [:]
    @State private var percentDrafts: [String: String] = [:]
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("When clients can book")
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("Per category. “Right away” is how booking works today. “After they finish prep” keeps your slot free until the client has answered the safety questions — worth it for big-ticket work you wouldn’t start without them.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textSecondary)

            if let actionError {
                BrandErrorBanner(message: actionError)
            }
            if let depositBlocker {
                Text(depositBlocker)
                    .font(BrandFont.body(11, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(BrandColor.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            switch phase {
            case .loading:
                HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                    .padding(.vertical, 16)
            case let .failed(message):
                Text(message)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            case .loaded:
                if categories.isEmpty {
                    Text("Add a service to your menu and its category shows up here.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textMuted)
                } else {
                    ForEach(categories) { card($0) }
                }
            }
        }
        .task { if case .loading = phase { await load() } }
    }

    @ViewBuilder
    private func card(_ row: ProCategoryBookingPolicy) -> some View {
        let busy = busyId == row.serviceCategoryId
        let locked = depositBlocker != nil

        VStack(alignment: .leading, spacing: 10) {
            Text(row.categoryName)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(BrandColor.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("When clients can book")
                    .font(BrandFont.body(11, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
                HStack(spacing: 8) {
                    gateChip(row: row, gate: .instant, label: "Right away", busy: busy)
                    gateChip(row: row, gate: .afterPrep, label: "After they finish prep", busy: busy)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Deposit for this category")
                    .font(BrandFont.body(11, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)

                HStack(spacing: 8) {
                    depositChip(
                        row: row,
                        selected: row.depositType == nil,
                        label: inheritedLabel,
                        busy: busy,
                        locked: locked
                    ) {
                        await save(row, depositType: .some(nil))
                    }

                    HStack(spacing: 3) {
                        Text("$")
                            .font(BrandFont.body(11, .semibold))
                            .foregroundStyle(BrandColor.textSecondary)
                        TextField("25", text: flatBinding(row))
                            .keyboardType(.decimalPad)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textPrimary)
                            .frame(width: 46)
                            .focused($focusedField, equals: "flat-\(row.serviceCategoryId)")
                            .disabled(busy || locked)
                            .accessibilityIdentifier("category-deposit-flat-\(row.serviceCategoryId)")
                        Button("Set") {
                            Task { await save(row, depositType: .some("FLAT")) }
                        }
                        .font(BrandFont.body(11, .semibold))
                        .tint(BrandColor.accent)
                        .disabled(busy || locked)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(
                        row.depositType == "FLAT"
                            ? BrandColor.accent.opacity(0.15)
                            : BrandColor.bgSecondary
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    HStack(spacing: 3) {
                        TextField("20", text: percentBinding(row))
                            .keyboardType(.numberPad)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textPrimary)
                            .frame(width: 34)
                            .focused($focusedField, equals: "pct-\(row.serviceCategoryId)")
                            .disabled(busy || locked)
                            .accessibilityIdentifier("category-deposit-percent-\(row.serviceCategoryId)")
                        Text("%")
                            .font(BrandFont.body(11, .semibold))
                            .foregroundStyle(BrandColor.textSecondary)
                        Button("Set") {
                            Task { await save(row, depositType: .some("PERCENT")) }
                        }
                        .font(BrandFont.body(11, .semibold))
                        .tint(BrandColor.accent)
                        .disabled(busy || locked)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(
                        row.depositType == "PERCENT"
                            ? BrandColor.accent.opacity(0.15)
                            : BrandColor.bgSecondary
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Text("Taken when the client books and credited against the total. Cancel more than 24 hours ahead and it goes back; inside 24 hours it’s yours. Whether a deposit applies at all still follows your payment settings — this only changes the amount for this category.")
                    .font(BrandFont.body(11))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func gateChip(
        row: ProCategoryBookingPolicy,
        gate: ProCategoryBookingGate,
        label: String,
        busy: Bool
    ) -> some View {
        let selected = row.bookingGate == gate
        Button {
            Task { await save(row, bookingGate: gate) }
        } label: {
            Text(label)
                .font(BrandFont.body(11, .semibold))
                .foregroundStyle(selected ? BrandColor.textPrimary : BrandColor.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? BrandColor.accent.opacity(0.15) : BrandColor.bgSecondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        selected ? BrandColor.accent : Color.clear,
                        lineWidth: 1
                    )
                )
        }
        .disabled(busy)
        .accessibilityIdentifier("category-gate-\(gate.rawValue)-\(row.serviceCategoryId)")
    }

    @ViewBuilder
    private func depositChip(
        row: ProCategoryBookingPolicy,
        selected: Bool,
        label: String,
        busy: Bool,
        locked: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Text(label)
                .font(BrandFont.body(11, .semibold))
                .foregroundStyle(selected ? BrandColor.textPrimary : BrandColor.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? BrandColor.accent.opacity(0.15) : BrandColor.bgSecondary)
                .clipShape(Capsule())
        }
        .disabled(busy || locked)
        .accessibilityIdentifier("category-deposit-inherit-\(row.serviceCategoryId)")
    }

    /// What a category inherits when it states nothing of its own.
    private var inheritedLabel: String {
        guard let account = accountDeposit, account.depositEnabled else { return "No deposit" }
        if account.depositType == "PERCENT", let percent = account.depositPercent {
            return "Your usual \(percent)%"
        }
        if account.depositType == "FLAT", let flat = account.depositFlatAmount {
            return "Your usual $\(flat)"
        }
        return "Your usual deposit"
    }

    private func flatBinding(_ row: ProCategoryBookingPolicy) -> Binding<String> {
        Binding(
            get: { flatDrafts[row.serviceCategoryId] ?? row.depositFlatAmount ?? "" },
            set: { flatDrafts[row.serviceCategoryId] = $0 }
        )
    }

    private func percentBinding(_ row: ProCategoryBookingPolicy) -> Binding<String> {
        Binding(
            get: {
                percentDrafts[row.serviceCategoryId]
                    ?? row.depositPercent.map(String.init)
                    ?? ""
            },
            set: { percentDrafts[row.serviceCategoryId] = $0 }
        )
    }

    private func load() async {
        do {
            let response = try await session.client.proProfile.categoryBookingPolicies()
            categories = response.categories
            accountDeposit = response.accountDeposit
            depositBlocker = response.depositBlocker
            phase = .loaded
        } catch {
            phase = .failed("Couldn’t load your category settings.")
        }
    }

    private func save(
        _ row: ProCategoryBookingPolicy,
        bookingGate: ProCategoryBookingGate? = nil,
        depositType: String?? = nil
    ) async {
        busyId = row.serviceCategoryId
        actionError = nil
        defer { busyId = nil }

        let flat = flatDrafts[row.serviceCategoryId] ?? row.depositFlatAmount
        let percent = Int(
            percentDrafts[row.serviceCategoryId]
                ?? row.depositPercent.map(String.init)
                ?? ""
        )

        do {
            try await session.client.proProfile.updateCategoryBookingPolicy(
                serviceCategoryId: row.serviceCategoryId,
                bookingGate: bookingGate,
                depositType: depositType,
                // Only sent when the type being SET needs them — the route reads
                // the amount that matches the type and ignores the other.
                depositFlatAmount: depositType == .some("FLAT") ? flat : nil,
                depositPercent: depositType == .some("PERCENT") ? percent : nil
            )
        } catch let e as APIError {
            // The server's own sentence. Its refusals name the setting that
            // fixes them ("Turn deposits on in your payment settings…"), and a
            // generic message here would throw away the actionable half.
            actionError = e.userMessage
        } catch {
            actionError = "Couldn’t save that. Try again."
        }
        await load()
    }
}
