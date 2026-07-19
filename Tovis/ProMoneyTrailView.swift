// Money-trail inspector — native port of the web `MoneyTrailInspector`
// (`app/_components/booking/MoneyTrailInspector.tsx`), 1:1. One trustworthy view of
// a booking's money: the Captured / Refunded / Net summary plus a flattened timeline
// of the deposit, final-bill charge, platform discovery fee, no-show / late-cancel
// fee, and every refund row. Reads `GET /api/v1/bookings/{id}/money-trail` and renders
// the server's numbers verbatim — it never re-derives money rules.
//
// It also carries the two WRITE actions the web inspector offers — a discretionary
// refund and a no-show-fee waive — each gated by the server's `capabilities` flags
// (never a client guess). Both POST the shared `/bookings/{id}/...` routes and reload
// the trail on success; a refund also `signalRefresh`es so the booking detail behind
// the sheet refreshes. This is the single native refund surface (the detail's old
// inline refund was removed) — matching web, where refund lives only here.
import SwiftUI
import TovisKit

struct ProMoneyTrailView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let bookingId: String

    private enum Phase {
        case loading
        case loaded(ProBookingMoneyTrail)
        case failed(String)
    }

    @State private var phase: Phase = .loading

    // Refund / waive WRITE actions (mirror the web inspector's action block).
    @State private var refundOpen = false
    @State private var refundAmount = ""
    @State private var refundReason = ""
    @State private var actionPending = false
    @State private var actionError: String?
    @State private var flash: String?
    @State private var showRefundConfirm = false
    @State private var showWaiveConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 80)
                case let .failed(message):
                    errorState(message)
                case let .loaded(trail):
                    content(trail)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Money trail")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }.tint(BrandColor.accent)
            }
        }
        .task { if case .loading = phase { await load() } }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ trail: ProBookingMoneyTrail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Every charge, fee, and refund on this booking.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
        }

        summaryCard(trail)
        timelineCard(trail)

        if let flash {
            banner(flash, tone: .success)
        }
        if let actionError {
            banner(actionError, tone: .danger)
        }

        if trail.capabilities.canRefund || trail.capabilities.canWaiveNoShowFee {
            actionsSection(trail)
        }
    }

    // MARK: - Refund / waive actions

    @ViewBuilder
    private func actionsSection(_ trail: ProBookingMoneyTrail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if refundOpen {
                refundForm(trail)
            } else {
                HStack(spacing: 10) {
                    if trail.capabilities.canRefund {
                        Button { openRefund() } label: { ghostLabel("Refund…") }
                            .buttonStyle(.plain).disabled(actionPending)
                    }
                    if trail.capabilities.canWaiveNoShowFee {
                        Button { showWaiveConfirm = true } label: {
                            ghostLabel(actionPending ? "Waiving…" : "Waive no-show fee")
                        }
                        .buttonStyle(.plain).disabled(actionPending)
                    }
                }
            }
        }
        .confirmationDialog(refundConfirmCopy(trail), isPresented: $showRefundConfirm, titleVisibility: .visible) {
            Button("Refund", role: .destructive) { Task { await submitRefund() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Waive this no-show fee? The client will not be charged.",
            isPresented: $showWaiveConfirm, titleVisibility: .visible
        ) {
            Button("Waive fee") { Task { await waive() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func refundForm(_ trail: ProBookingMoneyTrail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("AMOUNT (\(trail.currency.uppercased()))")
                    .font(BrandFont.mono(9)).tracking(0.6).foregroundStyle(BrandColor.textSecondary)
                TextField(fullAmountPlaceholder(trail), text: $refundAmount)
                    .keyboardType(.decimalPad)
                    .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
                    .padding(10).background(BrandColor.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("REASON (OPTIONAL)")
                    .font(BrandFont.mono(9)).tracking(0.6).foregroundStyle(BrandColor.textSecondary)
                TextField("e.g. service issue", text: $refundReason)
                    .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
                    .padding(10).background(BrandColor.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(spacing: 10) {
                Button { startRefund() } label: {
                    Group { actionPending ? Text("Refunding…") : Text("Confirm refund") }
                        .font(BrandFont.body(13, .semibold))
                        .padding(.vertical, 10).padding(.horizontal, 16)
                        .foregroundStyle(BrandColor.onAccent).background(BrandColor.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain).disabled(actionPending)
                Button { closeRefund() } label: { ghostLabel("Cancel") }
                    .buttonStyle(.plain).disabled(actionPending)
            }
        }
        .padding(12)
        .background(BrandColor.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func ghostLabel(_ title: String) -> some View {
        Text(title)
            .font(BrandFont.body(13, .semibold))
            .padding(.vertical, 10).padding(.horizontal, 16)
            .foregroundStyle(BrandColor.textPrimary).background(BrandColor.bgSecondary)
            .overlay(Capsule().stroke(BrandColor.textMuted.opacity(0.25), lineWidth: 1))
            .clipShape(Capsule())
    }

    private func banner(_ message: String, tone: Tone) -> some View {
        Text(message)
            .font(BrandFont.body(12, .semibold)).foregroundStyle(tone.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(tone.color.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tone.color.opacity(0.3), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func summaryCard(_ trail: ProBookingMoneyTrail) -> some View {
        HStack(spacing: 10) {
            statChip(
                "Captured",
                Wire.moneyCents(trail.summary.capturedCents, currency: trail.currency) ?? "—",
                tone: .muted
            )
            statChip(
                "Refunded",
                Wire.moneyCents(trail.summary.refundedCents, currency: trail.currency) ?? "—",
                tone: trail.summary.refundedCents > 0 ? .warn : .muted
            )
            statChip(
                "Net to pro",
                Wire.moneyCents(trail.summary.netCents, currency: trail.currency) ?? "—",
                tone: .success
            )
        }
    }

    private func statChip(_ label: String, _ value: String, tone: Tone) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(BrandFont.mono(8)).tracking(0.6)
                .foregroundStyle(BrandColor.textMuted)
            Text(value).font(BrandFont.display(16, .semibold)).foregroundStyle(tone.color).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(BrandColor.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func timelineCard(_ trail: ProBookingMoneyTrail) -> some View {
        let entries = buildEntries(trail)
        return BrandSurface {
            VStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    Text("No money has moved on this booking yet.")
                        .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(entries.enumerated()), id: \.element.key) { index, entry in
                        if index > 0 {
                            Divider().overlay(BrandColor.textMuted.opacity(0.15))
                        }
                        entryRow(entry)
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: TrailEntry) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(entry.tone.color.opacity(0.12))
                Circle().stroke(entry.tone.color.opacity(0.35), lineWidth: 1)
                Image(systemName: entry.flow.symbol)
                    .font(.system(size: entry.flow == .none ? 5 : 11, weight: .bold))
                    .foregroundStyle(entry.tone.color)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(entry.label).font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    Text(entry.status).font(BrandFont.mono(8)).tracking(0.8).foregroundStyle(entry.tone.color)
                }
                if let sub = entry.subtitle {
                    Text(sub).font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)

            if let amount = entry.amount {
                Text(entry.flow == .out ? "−\(amount)" : amount)
                    .font(BrandFont.display(13, .semibold))
                    .foregroundStyle(entry.flow == .out ? BrandColor.gold : BrandColor.textPrimary)
            }
        }
        .padding(.vertical, 10)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary).multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 70)
    }

    // MARK: - Load

    private func load() async {
        do {
            let trail = try await session.client.proBookings.moneyTrail(bookingId: bookingId)
            phase = .loaded(trail)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Failed to load the money trail.")
        }
    }

    // MARK: - Refund / waive (mirror web submitRefund / waiveNoShow)

    private func openRefund() {
        actionError = nil
        flash = nil
        refundOpen = true
    }

    private func closeRefund() {
        refundOpen = false
        actionError = nil
    }

    /// Validate the typed amount (blank = full), then raise the confirm dialog — the
    /// two-step "type then confirm" the detail's old refund used.
    private func startRefund() {
        let t = refundAmount.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, (Double(t) ?? -1) <= 0 {
            actionError = "Enter a positive amount, or leave blank to refund in full."
            return
        }
        actionError = nil
        showRefundConfirm = true
    }

    /// Dollars → integer cents; nil for blank (= refund the remaining balance in full).
    private func parseRefundCents() -> Int? {
        let t = refundAmount.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let dollars = Double(t), dollars > 0 else { return nil }
        return Int((dollars * 100).rounded())
    }

    private func fullAmountPlaceholder(_ trail: ProBookingMoneyTrail) -> String {
        String(format: "Full: %.2f", Double(trail.capabilities.refundableRemainingCents) / 100)
    }

    private func refundConfirmCopy(_ trail: ProBookingMoneyTrail) -> String {
        if parseRefundCents() == nil {
            let full = Wire.moneyCents(trail.capabilities.refundableRemainingCents, currency: trail.currency)
                ?? "the remaining balance"
            return "Refund the remaining \(full) to the client? This cannot be undone."
        }
        let amount = Wire.moneyCents(parseRefundCents(), currency: trail.currency)
            ?? refundAmount.trimmingCharacters(in: .whitespaces)
        return "Refund \(amount) to the client? This cannot be undone."
    }

    private func submitRefund() async {
        guard !actionPending else { return }
        actionPending = true; actionError = nil
        defer { actionPending = false }
        do {
            try await session.client.proBookings.refund(
                bookingId: bookingId,
                amountCents: parseRefundCents(),
                reason: refundReason.trimmedOrNil
            )
            flash = "Refund issued."
            refundOpen = false
            refundAmount = ""
            refundReason = ""
            session.signalRefresh()
            await load()
        } catch let error as APIError {
            actionError = error.userMessage
        } catch {
            actionError = "Network error while issuing the refund."
        }
    }

    private func waive() async {
        guard !actionPending else { return }
        actionPending = true; actionError = nil
        defer { actionPending = false }
        do {
            try await session.client.proBookings.waiveNoShowFee(bookingId: bookingId)
            flash = "No-show fee waived."
            session.signalRefresh()
            await load()
        } catch let error as APIError {
            actionError = error.userMessage
        } catch {
            actionError = "Network error while waiving the fee."
        }
    }

    // MARK: - Timeline model (mirrors web `buildEntries`)

    private enum Tone {
        case success, danger, warn, info, muted
        var color: Color {
            switch self {
            case .success: return BrandColor.emerald
            case .danger: return BrandColor.ember
            case .warn: return BrandColor.gold
            case .info: return BrandColor.iris
            case .muted: return BrandColor.textMuted
            }
        }
    }

    private enum Flow {
        case `in`, out, none
        /// SF Symbol for the direction dot: money in (↓), refunded out (↩), neutral (•).
        var symbol: String {
            switch self {
            case .in: return "arrow.down"
            case .out: return "arrow.uturn.backward"
            case .none: return "circle.fill"
            }
        }
    }

    private struct TrailEntry {
        let key: String
        let label: String
        let subtitle: String?
        let amount: String?
        let flow: Flow
        let tone: Tone
        let status: String
    }

    /// Flatten the structured trail into an ordered display timeline. 1:1 with the
    /// web `buildEntries`: deposit → final charge → discovery fee → no-show fee →
    /// refunds, joining each entry's detail with its relative age.
    private func buildEntries(_ trail: ProBookingMoneyTrail) -> [TrailEntry] {
        let currency = trail.currency
        var entries: [TrailEntry] = []

        func money(_ cents: Int?, _ code: String = currency) -> String? {
            Wire.moneyCents(cents, currency: code)
        }
        func joined(_ detail: String?, _ iso: String?) -> String? {
            let age = iso.map { Wire.relativeAgo($0) }
            return [detail, age?.isEmpty == false ? age : nil].compactMap { $0 }.joined(separator: " · ").trimmedOrNil
        }

        if let d = trail.deposit {
            let detail: String?
            if d.refundedCents > 0 {
                detail = "\(money(d.refundedCents) ?? "—") refunded"
            } else if d.creditedAt != nil {
                detail = "Credited to the final total"
            } else {
                detail = nil
            }
            entries.append(TrailEntry(
                key: "deposit", label: "Deposit",
                subtitle: joined(detail, d.paidAt),
                amount: money(d.amountCents), flow: .in,
                tone: d.status.uppercased() == "REFUNDED" ? .muted : .success,
                status: d.status
            ))
        }

        if let c = trail.finalCharge {
            let status = c.status.uppercased()
            let tone: Tone = status == "SUCCEEDED" ? .success : (status == "DISPUTED" ? .danger : .warn)
            entries.append(TrailEntry(
                key: "final-charge", label: "Final bill",
                subtitle: joined(status == "DISPUTED" ? "Payment disputed" : nil, c.paidAt),
                amount: money(c.capturedCents), flow: .in,
                tone: tone, status: c.status
            ))
        }

        if let f = trail.discoveryFee {
            let refunded = f.refundedAt != nil
            entries.append(TrailEntry(
                key: "discovery-fee", label: "Platform discovery fee",
                subtitle: refunded ? "Refunded" : nil,
                amount: money(f.amountCents), flow: .none,
                tone: refunded ? .muted : .info,
                status: refunded ? "REFUNDED" : "CHARGED"
            ))
        }

        if let n = trail.noShowFee {
            let status = n.status.uppercased()
            let detail: String?
            switch status {
            case "FAILED": detail = "Charge failed — card declined"
            case "WAIVED": detail = "Waived"
            case "SKIPPED": detail = "Not charged"
            default: detail = nil
            }
            let tone: Tone
            switch status {
            case "CHARGED": tone = .success
            case "FAILED": tone = .danger
            default: tone = .muted   // WAIVED / SKIPPED
            }
            entries.append(TrailEntry(
                key: "no-show-fee", label: "\(noShowReasonWord(n.reason)) fee",
                subtitle: joined(detail, n.chargedAt ?? n.markedAt),
                amount: money(n.amountCents),
                flow: status == "CHARGED" ? .in : .none,
                tone: tone, status: n.status
            ))
        }

        for r in trail.refunds {
            let status = r.status.uppercased()
            let tone: Tone
            switch status {
            case "SUCCEEDED": tone = .success
            case "FAILED", "CANCELED": tone = .danger
            default: tone = .warn   // PENDING
            }
            let detail = r.reason ?? (r.trigger.uppercased() == "AUTO_CANCELLATION" ? "Automatic (cancellation)" : nil)
            entries.append(TrailEntry(
                key: "refund-\(r.id)", label: "Refund",
                subtitle: joined(detail, r.createdAt),
                amount: money(r.amountCents, r.currency), flow: .out,
                tone: tone, status: r.status
            ))
        }

        return entries
    }

    /// "No-show" / "Late cancel" fee label word (web `noShowReasonLabel`). Falls
    /// back to "No-show" for a defensively-absent reason.
    private func noShowReasonWord(_ reason: String?) -> String {
        switch (reason ?? "").uppercased() {
        case "LATE_CANCEL": return "Late cancel"
        default: return "No-show"
        }
    }
}
