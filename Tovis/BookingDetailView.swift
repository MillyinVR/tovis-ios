// Booking detail — the full read-only view of one appointment, built from the
// ClientBookingDTO the bookings list already carries (no extra fetch; the
// backend has no standalone GET /bookings/[id] read endpoint). Actions
// (approve consultation, pay, reschedule) come in a later pass.
import SwiftUI
import TovisKit

struct BookingDetailView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let booking: ClientBooking
    /// Called after a successful decision so the list behind can refresh.
    var onDecision: () async -> Void = {}

    @State private var working = false
    @State private var actionError: String?

    private var isConsultationPending: Bool {
        booking.hasPendingConsultationApproval ||
            (booking.consultation?.approvalStatus?.uppercased() == "PENDING")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard

                if isConsultationPending {
                    noticeCard(
                        title: "Consultation needs your review",
                        subtitle: "Your pro proposed a plan — review and approve it.",
                        icon: "checklist", tint: BrandColor.gold
                    )
                    consultationActions
                }

                if !booking.items.isEmpty {
                    BrandSection(title: "Services") {
                        VStack(spacing: 10) {
                            ForEach(booking.items) { LineRow(name: itemName($0), amount: $0.price) }
                        }
                    }
                }

                if !booking.productSales.isEmpty {
                    BrandSection(title: "Products") {
                        VStack(spacing: 10) {
                            ForEach(booking.productSales) { sale in
                                LineRow(name: productName(sale), amount: sale.lineTotal)
                            }
                        }
                    }
                }

                if let consultation = booking.consultation, hasConsultationContent(consultation) {
                    BrandSection(title: "Consultation") {
                        ConsultationCard(consultation: consultation)
                    }
                }

                totalsCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Appointment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
    }

    // MARK: - Consultation actions

    private var consultationActions: some View {
        VStack(spacing: 10) {
            if let proposed = Wire.money(booking.consultation?.proposedTotal) {
                HStack {
                    Text("Proposed total")
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textSecondary)
                    Spacer()
                    Text(proposed)
                        .font(BrandFont.body(16, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                }
                .padding(.bottom, 2)
            }

            Button {
                Task { await decide(.approve) }
            } label: {
                actionLabel("Approve plan", filled: true)
            }
            .disabled(working)

            Button {
                Task { await decide(.reject) }
            } label: {
                actionLabel("Decline", filled: false)
            }
            .disabled(working)

            if let actionError {
                Text(actionError)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.ember)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func actionLabel(_ title: String, filled: Bool) -> some View {
        Group {
            if working {
                ProgressView().tint(filled ? BrandColor.onAccent : BrandColor.accent)
            } else {
                Text(title).font(BrandFont.body(16, .semibold))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .foregroundStyle(filled ? BrandColor.onAccent : BrandColor.ember)
        .background(filled ? BrandColor.accent : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(filled ? Color.clear : BrandColor.ember.opacity(0.4), lineWidth: 1)
        )
        .opacity(working ? 0.7 : 1)
    }

    private func decide(_ decision: ConsultationDecision) async {
        working = true
        actionError = nil
        defer { working = false }
        do {
            try await session.client.bookings.decideConsultation(
                bookingId: booking.id, decision
            )
            await onDecision()
            dismiss()
        } catch let error as APIError {
            actionError = error.userMessage
        } catch {
            actionError = "Something went wrong. Please try again."
        }
    }

    // MARK: - Cards

    private var headerCard: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if let pro = booking.professional {
                        BrandAvatar(name: pro.displayName, size: 52)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(booking.display.title)
                            .font(BrandFont.body(18, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        if let pro = booking.professional {
                            Text("with \(pro.displayName)")
                                .font(BrandFont.body(14))
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                    }
                    Spacer()
                }

                Divider().overlay(BrandColor.textMuted.opacity(0.15))

                infoRow(icon: "calendar",
                        text: Wire.dateTime(booking.scheduledFor, timeZone: booking.timeZone))
                infoRow(icon: "clock", text: "\(booking.totalDurationMinutes) min")
                if let place = booking.locationLabel {
                    infoRow(icon: "mappin.and.ellipse", text: place)
                }

                HStack(spacing: 10) {
                    if let status = booking.status {
                        BrandPill(text: status.capitalized, tint: statusTone(status))
                    }
                    if let source = bookingSource {
                        BrandPill(text: source)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private var totalsCard: some View {
        let c = booking.checkout
        return BrandSurface {
            VStack(spacing: 8) {
                totalLine("Subtotal", c.serviceSubtotalSnapshot ?? c.subtotalSnapshot)
                totalLine("Products", c.productSubtotalSnapshot)
                totalLine("Tax", c.taxAmount)
                totalLine("Tip", c.tipAmount)
                totalLine("Discount", c.discountAmount, negative: true)
                if c.totalAmount != nil {
                    Divider().overlay(BrandColor.textMuted.opacity(0.15))
                    HStack {
                        Text("Total")
                            .font(BrandFont.body(16, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Spacer()
                        Text(Wire.money(c.totalAmount) ?? "—")
                            .font(BrandFont.body(16, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                    }
                    if let paid = paidLine {
                        Text(paid)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.emerald)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func noticeCard(title: String, subtitle: String, icon: String, tint: Color) -> some View {
        BrandSurface(tint: tint.opacity(0.14)) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(subtitle)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                Spacer()
            }
        }
    }

    // MARK: - Bits

    private func infoRow(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(BrandFont.body(14))
            .foregroundStyle(BrandColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func totalLine(_ label: String, _ amount: String?, negative: Bool = false) -> some View {
        if let money = Wire.money(amount), money != "$0" {
            HStack {
                Text(label)
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textMuted)
                Spacer()
                Text(negative ? "−\(money)" : money)
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
    }

    private var bookingSource: String? {
        switch (booking.source ?? "").uppercased() {
        case "AFTERCARE": return "Pre-booked"
        case "PRO": return "Booked by pro"
        case "CLIENT": return nil
        case "": return nil
        default: return booking.source?.capitalized
        }
    }

    private var paidLine: String? {
        guard booking.checkout.paymentCollectedAt != nil else { return nil }
        return "Paid"
    }

    private func itemName(_ item: ClientBookingItem) -> String {
        item.isAddOn ? "+ \(item.name)" : item.name
    }

    private func productName(_ sale: ClientBookingProductSale) -> String {
        sale.quantity > 1 ? "\(sale.name) ×\(sale.quantity)" : sale.name
    }

    private func hasConsultationContent(_ c: ClientBookingConsultation) -> Bool {
        (c.consultationNotes?.isEmpty == false) ||
            (c.approvalNotes?.isEmpty == false) ||
            c.proposedTotal != nil ||
            c.approvalStatus != nil
    }
}

private struct LineRow: View {
    let name: String
    let amount: String

    var body: some View {
        BrandSurface {
            HStack {
                Text(name)
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer()
                Text(Wire.money(amount) ?? "—")
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
    }
}

private struct ConsultationCard: View {
    let consultation: ClientBookingConsultation

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                if let status = consultation.approvalStatus {
                    BrandPill(text: status.capitalized, tint: statusTone(status))
                }
                if let notes = consultation.consultationNotes, !notes.isEmpty {
                    Text(notes)
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                if let approvalNotes = consultation.approvalNotes, !approvalNotes.isEmpty {
                    Text(approvalNotes)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textMuted)
                }
                if let proposed = Wire.money(consultation.proposedTotal) {
                    HStack {
                        Text("Proposed total")
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textMuted)
                        Spacer()
                        Text(proposed)
                            .font(BrandFont.body(14, .semibold))
                            .foregroundStyle(BrandColor.accent)
                    }
                }
            }
        }
    }
}
