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

    // Pay leg (hosted Stripe Checkout)
    @State private var checkoutSheet: CheckoutSheet?
    @State private var creatingCheckout = false
    @State private var checkoutError: String?
    @State private var paidLocally = false

    /// A presented hosted Stripe Checkout page.
    private struct CheckoutSheet: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// Payment is collectable once the pro has finalized the bill (READY /
    /// PARTIALLY_PAID) and nothing has been collected yet. Mirrors the web
    /// "Pay" CTA on /client/bookings.
    private var paymentDue: Bool {
        guard !paidLocally, booking.checkout.paymentCollectedAt == nil else { return false }
        switch (booking.checkout.checkoutStatus ?? "").uppercased() {
        case "READY", "PARTIALLY_PAID": return true
        default: return false
        }
    }

    private var isPaid: Bool {
        paidLocally ||
            booking.checkout.paymentCollectedAt != nil ||
            (booking.checkout.checkoutStatus ?? "").uppercased() == "PAID"
    }

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

                payCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Appointment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .sheet(item: $checkoutSheet) { sheet in
            SafariView(url: sheet.url) {
                // Manual "Done" — the webhook may already have settled payment,
                // so refresh the list behind to surface the latest state.
                Task { await onDecision() }
            }
            .ignoresSafeArea()
        }
        .onChange(of: session.checkoutReturn) { _, ret in
            guard let ret, ret.bookingId == booking.id else { return }
            checkoutSheet = nil // dismiss the in-app browser
            if ret.status == .success { paidLocally = true }
            session.clearCheckoutReturn()
            Task { await onDecision() }
        }
    }

    // MARK: - Pay

    @ViewBuilder
    private var payCard: some View {
        if isPaid {
            BrandSurface(tint: BrandColor.emerald.opacity(0.14)) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(BrandColor.emerald)
                    Text("Payment received")
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                }
            }
        } else if paymentDue {
            VStack(spacing: 10) {
                Button {
                    Task { await startCheckout() }
                } label: {
                    Group {
                        if creatingCheckout {
                            ProgressView().tint(BrandColor.onAccent)
                        } else {
                            Text(payButtonTitle).font(BrandFont.body(17, .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .foregroundStyle(BrandColor.onAccent)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(creatingCheckout)

                if let checkoutError {
                    Text(checkoutError)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.ember)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var payButtonTitle: String {
        if let total = Wire.money(booking.checkout.totalAmount), total != "$0" {
            return "Pay \(total)"
        }
        return "Pay now"
    }

    private func startCheckout() async {
        guard !creatingCheckout else { return }
        creatingCheckout = true
        checkoutError = nil
        defer { creatingCheckout = false }
        do {
            let sessionResult = try await session.client.checkout.createCheckoutSession(
                bookingId: booking.id
            )
            guard let raw = sessionResult.url, let url = URL(string: raw) else {
                checkoutError = "Couldn’t open checkout. Please try again."
                return
            }
            checkoutSheet = CheckoutSheet(url: url)
        } catch let error as APIError {
            checkoutError = error.userMessage
        } catch {
            checkoutError = "Couldn’t start checkout. Please try again."
        }
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
                            NavigationLink {
                                ProProfileView(professionalId: pro.id, fallbackName: pro.displayName)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("with \(pro.displayName)")
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .font(BrandFont.body(14))
                                .foregroundStyle(BrandColor.accent)
                            }
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
