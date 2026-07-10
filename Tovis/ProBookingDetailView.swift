// Pro booking detail — native port of the web `/pro/bookings/[id]` page, 1:1. The
// calendar agenda is the list; tapping a booking opens this. Reads the authoritative
// detail (`GET /pro/bookings/[id]`) and renders the header card (Booking · #id ·
// TOTAL · client · when · tap-for-directions · Open session + Refund + lifecycle
// actions), a Timing timeline, a Payment breakdown, and an Aftercare snapshot. The
// lifecycle action set mirrors buildLifecycleActionViewModel (role PRO): PENDING →
// Accept + Cancel, ACCEPTED → Start booking + Cancel, IN_PROGRESS → Continue
// session, terminal → status text. (No rebook here — rebook lives on aftercare.)
import SwiftUI
import TovisKit

struct ProBookingDetailView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let bookingId: String
    /// The `step` carried on a tapped `/pro/bookings/{id}/…` push (e.g. `aftercare`);
    /// the detail scrolls to that section once loaded. nil = open at the top.
    var focusStep: String? = nil

    private enum Phase {
        case loading
        case loaded(ProBookingDetail)
        case failed(String)
    }

    /// Scroll anchors for a deep-linked step. Only sections that a push can target
    /// live here; everything else opens at the top.
    private enum Anchor: Hashable { case aftercare }

    @State private var phase: Phase = .loading
    /// One-shot guard so the deep-link scroll fires only on the first load.
    @State private var didFocus = false
    @State private var working = false
    @State private var actionError: String?
    @State private var pendingVerb: String?
    /// Error surfaced inline under the Payment card's "Confirm payment received"
    /// control (§10 off-platform payment confirmation).
    @State private var confirmPaymentError: String?

    @State private var showCancelConfirm = false

    // Edit-services sheet (mirrors the web calendar BookingModal service editor).
    @State private var showEditServices = false

    // Refund
    @State private var showRefund = false
    @State private var refundAmount = ""
    @State private var refundReason = ""
    @State private var refunding = false
    @State private var refundError: String?
    @State private var refundDone = false
    @State private var showRefundConfirm = false

    // Message-the-client entry point (mirrors web /pro/bookings/[id]).
    @State private var messageNav: MessageThreadNav?
    @State private var messageWorking = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch phase {
                    case .loading:
                        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                            .padding(.top, 80)
                    case let .failed(message):
                        errorState(message)
                    case let .loaded(booking):
                        content(booking)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 48)
            }
            .task { if case .loading = phase { await load(scroll: proxy) } }
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Booking")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .onChange(of: session.refreshTick) { Task { await load() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await openMessageThread() }
                } label: {
                    if messageWorking {
                        ProgressView().tint(BrandColor.accent)
                    } else {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                }
                .tint(BrandColor.accent)
                .disabled(messageWorking)
                .accessibilityLabel("Message client")
            }
        }
        .navigationDestination(item: $messageNav) { nav in
            ThreadView(thread: nav.thread)
        }
        .confirmationDialog("Cancel this booking? This will notify the client.", isPresented: $showCancelConfirm, titleVisibility: .visible) {
            Button("Cancel booking", role: .destructive) { Task { await cancel() } }
            Button("Keep it", role: .cancel) {}
        }
        .tint(BrandColor.accent)
    }

    /// Resolve-or-create this booking's thread and push the conversation.
    /// Best-effort: on failure the pro stays on the booking detail.
    private func openMessageThread() async {
        guard !messageWorking else { return }
        messageWorking = true
        defer { messageWorking = false }
        if let thread = try? await session.client.messages.openBookingThread(
            bookingId: bookingId
        ) {
            messageNav = MessageThreadNav(thread: thread)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ booking: ProBookingDetail) -> some View {
        statusRow(booking)
        headerCard(booking)
        servicesCard(booking)
        timingCard(booking)
        paymentCard(booking)
        aftercareCard(booking)
            .id(Anchor.aftercare)   // scroll anchor for a `…/aftercare` deep link
    }

    private func statusRow(_ booking: ProBookingDetail) -> some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(statusTone(booking.status)).frame(width: 6, height: 6)
                Text(booking.status.uppercased())
                    .font(BrandFont.mono(9)).tracking(1.2)
                    .foregroundStyle(statusTone(booking.status))
            }
            .padding(.vertical, 6).padding(.horizontal, 12)
            .overlay(Capsule().stroke(statusTone(booking.status).opacity(0.3), lineWidth: 1))
        }
    }

    // MARK: - Header card

    private func headerCard(_ booking: ProBookingDetail) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 14) {
                Text("Booking · #\(String(booking.id.suffix(6)).uppercased())")
                    .font(BrandFont.mono(10)).tracking(1.4)
                    .foregroundStyle(BrandColor.accent)

                HStack(alignment: .top) {
                    Text(booking.title)
                        .font(BrandFont.display(22, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("TOTAL").font(BrandFont.mono(8)).tracking(1.2).foregroundStyle(BrandColor.textMuted)
                        Text(Wire.money(booking.totalLabel) ?? "—")
                            .font(BrandFont.display(24, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                    }
                }

                Divider().overlay(BrandColor.textMuted.opacity(0.15))

                HStack(spacing: 10) {
                    BrandAvatar(name: booking.client.fullName, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(booking.client.fullName.isEmpty ? "Client" : booking.client.fullName)
                            .font(BrandFont.body(14, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        if let contact = clientContact(booking) {
                            Text(contact).font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted).lineLimit(1)
                        }
                    }
                    Spacer()
                }

                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(BrandColor.textMuted)
                    Text(whenLabel(booking)).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                    if let tz = booking.timeZone {
                        Text(tz).font(BrandFont.mono(8)).tracking(0.8).foregroundStyle(BrandColor.textMuted)
                    }
                }

                directionsTile(booking)

                actionButtons(booking)
            }
        }
    }

    @ViewBuilder
    private func directionsTile(_ booking: ProBookingDetail) -> some View {
        if let addr = booking.locationAddressSnapshot, !addr.isEmpty {
            let isMobile = booking.locationType.uppercased() == "MOBILE"
            let url = mapsURL(address: addr, lat: booking.locationLatSnapshot, lng: booking.locationLngSnapshot)
            let tile = HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 14))
                    .foregroundStyle(isMobile ? BrandColor.accent : BrandColor.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(isMobile ? "Mobile" : "Salon")\(url != nil ? " · tap for directions" : "")")
                        .font(BrandFont.mono(8)).tracking(0.8).foregroundStyle(BrandColor.textMuted)
                    Text(addr).font(BrandFont.body(13)).foregroundStyle(BrandColor.textPrimary).lineLimit(1)
                }
                Spacer()
                if url != nil {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 13)).foregroundStyle(BrandColor.textMuted)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(BrandColor.bgPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let url { Link(destination: url) { tile } } else { tile }
        }
    }

    // MARK: - Lifecycle actions (mirror buildLifecycleActionViewModel, role PRO)

    @ViewBuilder
    private func actionButtons(_ booking: ProBookingDetail) -> some View {
        VStack(spacing: 10) {
            // Header always offers Open session + Refund (when refundable).
            HStack(spacing: 10) {
                NavigationLink { ProSessionHubView(bookingId: booking.id) } label: {
                    primaryLabel("Open session →")
                }
                if booking.canRefund {
                    Button { showRefund.toggle(); refundError = nil } label: { ghostLabel("Refund") }
                        .disabled(refunding)
                }
            }

            if showRefund && booking.canRefund { refundForm(booking) }

            if let actionError {
                Text(actionError).font(BrandFont.body(12)).foregroundStyle(BrandColor.ember)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The lifecycle action row (status-driven).
            lifecycleRow(booking)
        }
    }

    @ViewBuilder
    private func lifecycleRow(_ booking: ProBookingDetail) -> some View {
        let step = (booking.sessionStep ?? "NONE").uppercased()
        if booking.isPending {
            HStack(spacing: 10) {
                actionButton("Accept", primary: true, verb: "ACCEPT") { await accept() }
                cancelButton
            }
        } else if booking.isAccepted {
            HStack(spacing: 10) {
                actionButton("Start booking", primary: true, verb: "START") { await startSession() }
                cancelButton
            }
        } else if booking.isInProgress && step != "DONE" {
            NavigationLink { ProSessionHubView(bookingId: booking.id) } label: {
                primaryLabel("Continue session")
            }
        } else {
            Text("Status: \(statusDisplayLabel(booking))")
                .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cancelButton: some View {
        Button { showCancelConfirm = true } label: {
            Text(pendingVerb == "CANCEL" ? "Cancel…" : "Cancel")
                .font(BrandFont.body(13, .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundStyle(BrandColor.textPrimary).background(BrandColor.bgPrimary)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BrandColor.textMuted.opacity(0.2), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(pendingVerb != nil)
    }

    private func actionButton(_ title: String, primary: Bool, verb: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Group { pendingVerb == verb ? Text("\(title)…") : Text(title) }
                .font(BrandFont.body(13, .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundStyle(primary ? BrandColor.onAccent : BrandColor.textPrimary)
                .background(primary ? BrandColor.accent : BrandColor.bgPrimary)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BrandColor.textMuted.opacity(primary ? 0 : 0.2), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(pendingVerb != nil)
    }

    // MARK: - Refund form

    private func refundForm(_ booking: ProBookingDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if refundDone {
                Text("Refund issued.").font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("AMOUNT (\((booking.stripeCurrency ?? "usd").uppercased()))")
                        .font(BrandFont.mono(9)).tracking(0.6).foregroundStyle(BrandColor.textSecondary)
                    TextField(fullAmountPlaceholder(booking), text: $refundAmount)
                        .keyboardType(.decimalPad)
                        .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
                        .padding(10).background(BrandColor.bgSecondary).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("REASON (OPTIONAL)").font(BrandFont.mono(9)).tracking(0.6).foregroundStyle(BrandColor.textSecondary)
                    TextField("e.g. client cancelled late", text: $refundReason)
                        .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
                        .padding(10).background(BrandColor.bgSecondary).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if let refundError {
                    Text(refundError).font(BrandFont.body(11, .semibold)).foregroundStyle(BrandColor.ember)
                }
                HStack(spacing: 10) {
                    Button { startRefund() } label: {
                        Group { refunding ? Text("Refunding…") : Text("Confirm refund") }
                            .font(BrandFont.body(13, .semibold))
                            .padding(.vertical, 10).padding(.horizontal, 16)
                            .foregroundStyle(BrandColor.onAccent).background(BrandColor.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain).disabled(refunding)
                    Button { showRefund = false; refundError = nil } label: { ghostLabel("Cancel") }
                        .disabled(refunding)
                }
            }
        }
        .padding(12)
        .background(BrandColor.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .confirmationDialog(refundConfirmCopy(booking), isPresented: $showRefundConfirm, titleVisibility: .visible) {
            Button("Refund", role: .destructive) { Task { await refund(booking) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Services

    /// The booked services (base + add-ons), with an Edit affordance that opens the
    /// service editor while the booking is non-terminal (the server rejects editing
    /// a CANCELLED / COMPLETED booking). First native surface to change the services
    /// on an existing booking.
    private func servicesCard(_ booking: ProBookingDetail) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Services").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        Text("What’s booked for this appointment.").font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                    }
                    Spacer()
                    if !booking.isTerminal {
                        Button { showEditServices = true } label: {
                            Text("Edit").font(BrandFont.body(12, .semibold))
                                .padding(.vertical, 6).padding(.horizontal, 14)
                                .foregroundStyle(BrandColor.accent)
                                .overlay(Capsule().stroke(BrandColor.accent.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if booking.serviceItems.isEmpty {
                    Text("No services on this booking.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(sortedServiceItems(booking.serviceItems)) { item in
                        serviceItemRow(item)
                    }
                }
            }
        }
        .sheet(isPresented: $showEditServices) {
            NavigationStack {
                ProEditServiceItemsView(
                    bookingId: booking.id,
                    locationType: booking.locationType,
                    initialItems: booking.serviceItems,
                    onSaved: { session.signalRefresh() }
                )
            }
        }
    }

    /// Base item(s) first, then add-ons — each by sortOrder (matches the editor).
    private func sortedServiceItems(_ items: [ProBookingServiceItem]) -> [ProBookingServiceItem] {
        items.sorted { a, b in
            if a.isAddOn != b.isAddOn { return !a.isAddOn }
            return a.sortOrder < b.sortOrder
        }
    }

    private func serviceItemRow(_ item: ProBookingServiceItem) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.serviceName).font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    if item.isAddOn { BrandPill(text: "ADD-ON", tint: BrandColor.textMuted) }
                }
                if item.durationMinutesSnapshot > 0 {
                    Text("\(item.durationMinutesSnapshot) min").font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                }
            }
            Spacer()
            if let price = item.priceSnapshot, let money = Wire.money(price) {
                Text(money).font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Timing

    private func timingCard(_ booking: ProBookingDetail) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                Text("Timing").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("State timestamps for this booking.").font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                timingRow("Scheduled", value: Wire.dateTime(booking.scheduledFor, timeZone: booking.timeZone), done: true)
                timingRow("Started", value: stamp(booking.startedAt, tz: booking.timeZone), done: booking.startedAt != nil)
                timingRow("Finished", value: stamp(booking.finishedAt, tz: booking.timeZone), done: booking.finishedAt != nil)
            }
        }
    }

    private func timingRow(_ label: String, value: String, done: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(done ? BrandColor.accent.opacity(0.4) : BrandColor.textMuted.opacity(0.25), lineWidth: 1)
                    .background(Circle().fill(done ? BrandColor.accent.opacity(0.12) : Color.clear))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(BrandColor.accent)
                } else {
                    Circle().fill(BrandColor.textMuted).frame(width: 5, height: 5)
                }
            }
            .frame(width: 22, height: 22)
            Text(label).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
            Spacer()
            Text(value).font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
        }
        .padding(.top, 6)
    }

    // MARK: - Payment

    private func paymentCard(_ booking: ProBookingDetail) -> some View {
        let total = Wire.money(booking.totalLabel) ?? "—"
        return BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                Text("Payment").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text(booking.isPaid ? "Collected and reconciled." : "Not collected yet.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)

                HStack(spacing: 10) {
                    Image(systemName: "creditcard")
                        .font(.system(size: 16)).foregroundStyle(booking.isPaid ? BrandColor.accent : BrandColor.gold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(booking.isPaid ? "Paid\(methodSuffix(booking))" : "Awaiting payment")
                            .font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        Text(booking.isPaid ? "\(total) collected" : "\(total) due")
                            .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                    }
                    Spacer()
                }
                .padding(10)
                .background((booking.isPaid ? BrandColor.accent : BrandColor.gold).opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke((booking.isPaid ? BrandColor.accent : BrandColor.gold).opacity(0.3), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                // Off-platform payment the client attested to (AWAITING_CONFIRMATION):
                // the pro confirms receipt right here on the detail, mirroring the
                // session wrap-up control. Confirming also auto-approves any coupled
                // aftercare next appointment.
                if booking.isAwaitingPaymentConfirmation {
                    confirmPaymentControl()
                }

                VStack(spacing: 6) {
                    if let services = booking.serviceSubtotalSnapshot ?? booking.subtotalSnapshot {
                        moneyRow("Services", value: Wire.money(services) ?? "—")
                    }
                    if let discount = booking.discountAmount {
                        moneyRow("Discount", value: "-\(Wire.money(discount) ?? "—")")
                    }
                    if let tax = booking.taxAmount { moneyRow("Tax", value: Wire.money(tax) ?? "—") }
                    if let tip = booking.tipAmount { moneyRow("Tip", value: Wire.money(tip) ?? "—") }
                    Divider().overlay(BrandColor.textMuted.opacity(0.15)).padding(.top, 2)
                    moneyRow("Total", value: total, strong: true)
                }
                .padding(.top, 4)
            }
        }
    }

    /// "Confirm payment received" control for an off-platform payment the client
    /// attested to (checkout AWAITING_CONFIRMATION → PAID). Mirrors the session
    /// wrap-up control; confirming auto-approves any coupled aftercare next booking.
    @ViewBuilder
    private func confirmPaymentControl() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The client marked this payment as sent. Confirm once you’ve received it to close out the booking.")
                .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { Task { await confirmPayment() } } label: {
                Text(pendingVerb == "CONFIRM_PAYMENT" ? "Confirming…" : "Confirm payment received")
                    .font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.onAccent)
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(BrandColor.emerald)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(pendingVerb != nil)

            Text("This also approves the next booking the client requested.")
                .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)

            if let confirmPaymentError {
                Text(confirmPaymentError).font(BrandFont.body(11)).foregroundStyle(BrandColor.ember)
            }
        }
        .padding(.top, 2)
    }

    private func moneyRow(_ label: String, value: String, strong: Bool = false) -> some View {
        HStack {
            Text(label).font(BrandFont.body(12.5, strong ? .semibold : .regular))
                .foregroundStyle(strong ? BrandColor.textPrimary : BrandColor.textMuted)
            Spacer()
            Text(value).font(BrandFont.body(12.5, .semibold)).foregroundStyle(BrandColor.textPrimary)
        }
    }

    // MARK: - Aftercare snapshot

    private func aftercareCard(_ booking: ProBookingDetail) -> some View {
        let ac = booking.aftercareSummary
        return BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aftercare").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        Text(aftercareSubtitle(ac)).font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                    }
                    Spacer()
                    if ac?.isSent == true {
                        BrandPill(text: "Sent", tint: BrandColor.accent)
                    } else if ac?.isDraft == true {
                        BrandPill(text: "Draft", tint: BrandColor.gold)
                    }
                }
                if let notes = ac?.notes, !notes.isEmpty {
                    Text(notes)
                        .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(BrandColor.bgPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Text("No aftercare notes yet.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(BrandColor.bgPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    // MARK: - Labels / helpers

    private func clientContact(_ booking: ProBookingDetail) -> String? {
        [booking.client.email, booking.client.phone].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    private func whenLabel(_ booking: ProBookingDetail) -> String {
        var s = Wire.dateTime(booking.scheduledFor, timeZone: booking.timeZone)
        if booking.totalDurationMinutes > 0 { s += " · \(booking.totalDurationMinutes) min" }
        return s
    }

    private func stamp(_ iso: String?, tz: String?) -> String {
        guard let iso else { return "—" }
        return Wire.dateTime(iso, timeZone: tz)
    }

    private func methodSuffix(_ booking: ProBookingDetail) -> String {
        if let method = booking.selectedPaymentMethod {
            return " · \(humanizeMethod(method))"
        }
        if booking.stripePaymentStatus != nil { return " · Card" }
        return ""
    }

    private func humanizeMethod(_ raw: String) -> String {
        raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    private func aftercareSubtitle(_ ac: ProAftercareSnapshot?) -> String {
        if ac?.isSent == true {
            if let v = ac?.version { return "Sent to client · v\(v)" }
            return "Sent to client"
        }
        if ac?.isDraft == true { return "Draft saved" }
        return "Snapshot saved on the booking (if provided)."
    }

    private func statusDisplayLabel(_ booking: ProBookingDetail) -> String {
        switch booking.status.uppercased() {
        case "PENDING": return "Pending"
        case "ACCEPTED": return "Confirmed"
        case "COMPLETED": return "Completed"
        case "CANCELLED": return "Cancelled"
        case "IN_PROGRESS": return "In progress"
        default: return booking.status.capitalized
        }
    }

    private func mapsURL(address: String, lat: Double?, lng: Double?) -> URL? {
        if let lat, let lng {
            return URL(string: "http://maps.apple.com/?ll=\(lat),\(lng)&q=\(address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        }
        guard let q = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "http://maps.apple.com/?q=\(q)")
    }

    private func fullAmountPlaceholder(_ booking: ProBookingDetail) -> String {
        if let cents = booking.stripeAmountTotal {
            return String(format: "Full: %.2f", Double(cents) / 100)
        }
        return "Full amount"
    }

    private func refundConfirmCopy(_ booking: ProBookingDetail) -> String {
        let cents = parseRefundCents()
        if cents == nil {
            let full = booking.stripeAmountTotal.map { String(format: " (full: %.2f %@)", Double($0) / 100, (booking.stripeCurrency ?? "usd").uppercased()) } ?? ""
            return "Refund this booking in full\(full)? This cannot be undone."
        }
        return "Refund \(refundAmount.trimmingCharacters(in: .whitespaces)) \((booking.stripeCurrency ?? "usd").uppercased()) for this booking? This cannot be undone."
    }

    private func parseRefundCents() -> Int? {
        let t = refundAmount.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let dollars = Double(t), dollars > 0 else { return nil }
        return Int((dollars * 100).rounded())
    }

    private func primaryLabel(_ title: String) -> some View {
        Text(title)
            .font(BrandFont.body(14, .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .foregroundStyle(BrandColor.onAccent).background(BrandColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func ghostLabel(_ title: String) -> some View {
        Text(title)
            .font(BrandFont.body(13, .semibold))
            .padding(.vertical, 12).padding(.horizontal, 18)
            .foregroundStyle(BrandColor.textPrimary).background(BrandColor.bgPrimary)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BrandColor.textMuted.opacity(0.2), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    // MARK: - Actions

    private func load(scroll proxy: ScrollViewProxy? = nil) async {
        do {
            let detail = try await session.client.proBookings.detail(bookingId: bookingId)
            phase = .loaded(detail)
            await focus(proxy)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Failed to load booking.")
        }
    }

    /// The step this push targeted, resolved to a scroll anchor (nil = top).
    private var focusAnchor: Anchor? {
        switch focusStep?.lowercased() {
        case "aftercare": return .aftercare
        default: return nil   // session / overview / nil → the booking opens at the top
        }
    }

    /// Scroll to the deep-linked section once, after the detail has rendered. The
    /// brief delay lets the sheet-present animation settle and the cards lay out.
    private func focus(_ proxy: ScrollViewProxy?) async {
        guard !didFocus, let proxy, let anchor = focusAnchor else { return }
        didFocus = true
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation { proxy.scrollTo(anchor, anchor: .top) }
    }

    private func accept() async {
        guard pendingVerb == nil else { return }
        pendingVerb = "ACCEPT"; actionError = nil
        defer { pendingVerb = nil }
        do {
            try await session.client.proBookings.accept(bookingId: bookingId)
            session.signalRefresh(); await load()
        } catch let error as APIError { actionError = error.userMessage }
        catch { actionError = "Couldn’t accept the request. Try again." }
    }

    private func startSession() async {
        guard pendingVerb == nil else { return }
        pendingVerb = "START"; actionError = nil
        defer { pendingVerb = nil }
        do {
            try await session.client.proBookings.startSession(bookingId: bookingId)
            session.signalRefresh(); await load()
        } catch let error as APIError { actionError = error.userMessage }
        catch { actionError = "Couldn’t start the booking. Try again." }
    }

    private func cancel() async {
        guard pendingVerb == nil else { return }
        pendingVerb = "CANCEL"; actionError = nil
        defer { pendingVerb = nil }
        do {
            try await session.client.proBookings.cancel(bookingId: bookingId)
            session.signalRefresh(); dismiss()
        } catch let error as APIError { actionError = error.userMessage }
        catch { actionError = "Couldn’t cancel the booking. Try again." }
    }

    private func confirmPayment() async {
        guard pendingVerb == nil else { return }
        pendingVerb = "CONFIRM_PAYMENT"; confirmPaymentError = nil
        defer { pendingVerb = nil }
        do {
            try await session.client.proBookings.confirmPayment(bookingId: bookingId)
            session.signalRefresh(); await load()
        } catch let error as APIError { confirmPaymentError = error.userMessage }
        catch { confirmPaymentError = "Could not confirm payment. Check your connection and try again." }
    }

    private func startRefund() {
        // Validate before the confirm dialog (mirrors the web's positive-amount check).
        let t = refundAmount.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, (Double(t) ?? -1) <= 0 {
            refundError = "Enter a positive amount, or leave blank to refund in full."
            return
        }
        refundError = nil
        showRefundConfirm = true
    }

    private func refund(_ booking: ProBookingDetail) async {
        guard !refunding else { return }
        refunding = true; refundError = nil
        defer { refunding = false }
        do {
            try await session.client.proBookings.refund(
                bookingId: bookingId,
                amountCents: parseRefundCents(),
                reason: refundReason.trimmingCharacters(in: .whitespaces).nilIfEmpty
            )
            refundDone = true
            session.signalRefresh(); await load()
        } catch let error as APIError { refundError = error.userMessage }
        catch { refundError = "Network error while refunding." }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
