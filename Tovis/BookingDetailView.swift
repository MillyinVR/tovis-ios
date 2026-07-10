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
    /// The `step` carried on a tapped `/client/bookings/{id}?step=…` push; the detail
    /// scrolls to that section once shown. nil / `overview` / `review` open at the top.
    var focusStep: String? = nil

    /// Scroll anchors for a deep-linked step. Only sections a push can target live
    /// here; everything else opens at the top.
    private enum Anchor: Hashable { case consult, aftercare }
    /// One-shot guard so the deep-link scroll fires only on first appearance.
    @State private var didFocus = false

    @State private var working = false
    @State private var actionError: String?

    // Rebook confirmation (pro proposed a next appointment)
    @State private var decidingRebook = false
    @State private var rebookDecidedLocally = false
    @State private var rebookError: String?

    // Pay leg (hosted Stripe Checkout)
    @State private var checkoutSheet: CheckoutSheet?
    @State private var creatingCheckout = false
    @State private var checkoutError: String?
    @State private var paidLocally = false

    // Deposit leg (discovery deposit + one-time platform fee)
    @State private var creatingDeposit = false
    @State private var depositError: String?
    @State private var depositPaidLocally = false

    // Media-use consent (B3b)
    @State private var consentLocal: Bool?
    @State private var consentWorking = false
    @State private var consentError: String?

    // Aftercare (care notes + featured before/after) — loaded lazily for a
    // past/completed booking (or one with unread aftercare); supplementary, so
    // a load failure just hides the section (§24 AF3b).
    @State private var aftercare: ClientAftercareDetail?
    @State private var loadingAftercare = false

    // Manage leg (reschedule / cancel)
    @State private var rescheduleSheet: RescheduleContext?
    @State private var loadingReschedule = false
    @State private var showCancelConfirm = false
    @State private var cancelling = false
    @State private var cancelledLocally = false
    @State private var manageError: String?

    /// A presented hosted Stripe Checkout page.
    private struct CheckoutSheet: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// The resolved offering for a reschedule, presented as the booking flow.
    private struct RescheduleContext: Identifiable {
        let id = UUID()
        let offering: ProOffering
        let professionalId: String
        let proName: String
        let locationType: String
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

    /// The client already marked an off-platform payment (cash / Venmo / Zelle /
    /// Apple Cash / PayPal) as sent; it's authorized on their word and closes out
    /// only once the pro confirms receipt (web `AWAITING_CONFIRMATION`). There's
    /// nothing left for the client to do here — freeze the pay controls and show a
    /// waiting banner. Mirrors web `ClientCheckoutCard`.
    private var awaitingConfirmation: Bool {
        !paidLocally &&
            booking.checkout.paymentCollectedAt == nil &&
            (booking.checkout.checkoutStatus ?? "").uppercased() == "AWAITING_CONFIRMATION"
    }

    /// A discovery deposit is owed exactly while its status is PENDING (the same
    /// gate the backend's deposit/stripe-session route enforces). `depositPaidLocally`
    /// flips it off optimistically once the deposit return lands.
    private var depositDue: Bool {
        !depositPaidLocally &&
            (booking.checkout.depositStatus ?? "").uppercased() == "PENDING"
    }

    private var depositPaid: Bool {
        depositPaidLocally ||
            (booking.checkout.depositStatus ?? "").uppercased() == "PAID"
    }

    private var isConsultationPending: Bool {
        booking.hasPendingConsultationApproval ||
            (booking.consultation?.approvalStatus?.uppercased() == "PENDING")
    }

    /// The pro proposed a next appointment the client hasn't acted on yet.
    private var isRebookPending: Bool {
        booking.hasPendingRebookConfirmation && !rebookDecidedLocally
    }

    /// Reschedule/cancel are offered for an active, still-upcoming booking. Past,
    /// cancelled, or completed bookings can't be changed.
    private var isManageable: Bool {
        if cancelledLocally { return false }
        switch (booking.status ?? "").uppercased() {
        case "CANCELLED", "COMPLETED", "NO_SHOW", "DECLINED", "EXPIRED":
            return false
        default:
            break
        }
        guard let when = Wire.date(booking.scheduledFor) else { return true }
        return when > Date()
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard

                // Aftercare-sourced next appointment whose approval is coupled to
                // the previous visit's off-platform payment — it stays PENDING until
                // the pro confirms that payment (§10). Nothing for the client to do.
                if booking.isCoupledRebookAwaitingPaymentConfirmation {
                    noticeCard(
                        title: "Pending — your pro will confirm",
                        subtitle: "This appointment is booked. Your pro confirms it once they’ve received payment for your last visit.",
                        icon: "hourglass", tint: BrandColor.gold
                    )
                }

                if isConsultationPending {
                    noticeCard(
                        title: "Consultation needs your review",
                        subtitle: "Your pro proposed a plan — review and approve it.",
                        icon: "checklist", tint: BrandColor.gold
                    )
                    .id(Anchor.consult)   // scroll anchor for a `?step=consult` deep link
                    consultationActions
                }

                if isRebookPending {
                    rebookCard
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

                depositCard

                payCard

                aftercareCard
                    .id(Anchor.aftercare)   // scroll anchor for a `?step=aftercare` deep link

                mediaConsentCard

                manageCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .task {
            // Load aftercare before resolving a deep-linked scroll so the
            // aftercare anchor exists when a `?step=aftercare` push scrolls to it.
            await loadAftercare()
            await focus(proxy)
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
        .sheet(item: $rescheduleSheet) { ctx in
            BookingFlowView(
                professionalId: ctx.professionalId,
                proName: ctx.proName,
                offering: ctx.offering,
                rescheduleBookingId: booking.id,
                locationType: ctx.locationType
            )
            .onDisappear { Task { await onDecision() } }
        }
        .confirmationDialog(
            "Cancel this appointment?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Cancel appointment", role: .destructive) {
                Task { await cancelBooking() }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Cancelling within 24 hours of the appointment may not be refunded.")
        }
        .onChange(of: session.checkoutReturn) { _, ret in
            guard let ret, ret.bookingId == booking.id else { return }
            checkoutSheet = nil // dismiss the in-app browser
            if ret.status == .success {
                // The same return scheme carries both legs — flip the one that paid.
                switch ret.kind {
                case .deposit: depositPaidLocally = true
                case .checkout: paidLocally = true
                }
            }
            session.clearCheckoutReturn()
            Task { await onDecision() }
        }
        }
    }

    /// The step this push targeted, resolved to a scroll anchor (nil = top).
    private var focusAnchor: Anchor? {
        switch focusStep?.lowercased() {
        case "consult": return .consult
        case "aftercare": return .aftercare
        default: return nil   // overview / review / nil → the detail opens at the top
        }
    }

    /// Scroll to the deep-linked section once, after the detail has rendered. The
    /// brief delay lets the sheet-present animation settle and the cards lay out so
    /// the anchor resolves. A no-op when the target section isn't on screen.
    private func focus(_ proxy: ScrollViewProxy) async {
        guard !didFocus, let anchor = focusAnchor else { return }
        didFocus = true
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation { proxy.scrollTo(anchor, anchor: .top) }
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
        } else if awaitingConfirmation {
            BrandSurface(tint: BrandColor.gold.opacity(0.12)) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "clock.badge.checkmark")
                        .foregroundStyle(BrandColor.gold)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Payment sent — waiting on your pro")
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text("Once your pro confirms they received payment, your booking will close out. There’s nothing else you need to do.")
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                    Spacer(minLength: 0)
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

    // MARK: - Deposit (discovery deposit + one-time platform fee)

    @ViewBuilder
    private var depositCard: some View {
        if depositPaid {
            BrandSurface(tint: BrandColor.emerald.opacity(0.14)) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill").foregroundStyle(BrandColor.emerald)
                    Text("Deposit paid")
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                }
            }
        } else if depositDue {
            BrandSurface {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.shield").foregroundStyle(BrandColor.accent)
                        Text("Secure your booking")
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Spacer()
                    }
                    Text("Your pro asks for a deposit to hold this appointment. It goes toward your total.")
                        .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)

                    Button { Task { await startDeposit() } } label: {
                        Group {
                            if creatingDeposit { ProgressView().tint(BrandColor.onAccent) }
                            else { Text(depositButtonTitle).font(BrandFont.body(16, .semibold)) }
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .foregroundStyle(BrandColor.onAccent)
                        .background(BrandColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(creatingDeposit)

                    if let depositError {
                        Text(depositError)
                            .font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
            }
        }
    }

    private var depositButtonTitle: String {
        if let amount = Wire.money(booking.checkout.depositAmount), amount != "$0" {
            return "Pay \(amount) deposit"
        }
        return "Pay deposit"
    }

    private func startDeposit() async {
        guard !creatingDeposit else { return }
        creatingDeposit = true
        depositError = nil
        defer { creatingDeposit = false }
        do {
            let result = try await session.client.checkout.createDepositSession(bookingId: booking.id)
            guard let raw = result.stripeCheckout.url, let url = URL(string: raw) else {
                depositError = "Couldn’t open the deposit checkout. Please try again."
                return
            }
            checkoutSheet = CheckoutSheet(url: url)
        } catch let error as APIError {
            depositError = error.userMessage
        } catch {
            depositError = "Couldn’t start the deposit. Please try again."
        }
    }

    // MARK: - Aftercare (care notes + featured before/after) — §24 AF3b

    /// Fetch aftercare once the session has happened (past/completed) or there's
    /// unread aftercare — the same window the web shows the aftercare tab in.
    private var shouldLoadAftercare: Bool {
        showsMediaConsent || booking.hasUnreadAftercare
    }

    private func loadAftercare() async {
        guard shouldLoadAftercare, aftercare == nil, !loadingAftercare else { return }
        loadingAftercare = true
        defer { loadingAftercare = false }
        // Best-effort: aftercare is supplementary to the appointment detail, so
        // a failure simply leaves the section hidden.
        aftercare = try? await session.client.bookings.aftercare(bookingId: booking.id)
    }

    @ViewBuilder
    private var aftercareCard: some View {
        if let detail = aftercare, detail.canShowAftercare, detail.hasContent {
            BrandSection(title: "Aftercare") {
                VStack(alignment: .leading, spacing: 14) {
                    if detail.beforeAfter.hasAny {
                        AftercareBeforeAfterPair(
                            beforeUrl: detail.beforeAfter.beforePreferred,
                            afterUrl: detail.beforeAfter.afterPreferred,
                            compareHeight: 300
                        )
                        aftercarePrivacyNote
                    }

                    if let notes = detail.aftercare?.notes,
                       !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        careNotesCard(notes)
                    }
                }
            }
        }
    }

    /// Parity with web's `AftercarePrivacyNote` — reassure the client the
    /// session photos stay private unless they add them to a review.
    private var aftercarePrivacyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(BrandColor.textMuted)
            Text("These photos are private — only you and your pro can see them, unless you add them to a review.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private func careNotesCard(_ notes: String) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text("Care instructions")
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text(notes)
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Media-use consent (B3b)

    /// Show the consent toggle once the session has happened (there are/will be
    /// before/after photos to share). Past or completed bookings qualify.
    private var showsMediaConsent: Bool {
        if (booking.status ?? "").uppercased() == "COMPLETED" { return true }
        if let when = Wire.date(booking.scheduledFor) { return when < Date() }
        return false
    }

    private var mediaConsentGranted: Bool { consentLocal ?? booking.mediaUseConsent }

    @ViewBuilder
    private var mediaConsentCard: some View {
        if showsMediaConsent {
            BrandSection(title: "Photos & sharing") {
                BrandSurface {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { mediaConsentGranted },
                            set: { newValue in Task { await setConsent(newValue) } }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Allow \(proFirstName) to feature my photos & video")
                                    .font(BrandFont.body(15, .semibold))
                                    .foregroundStyle(BrandColor.textPrimary)
                                Text("Lets your pro share this session's before/after on their portfolio. You can turn this off anytime.")
                                    .font(BrandFont.body(12))
                                    .foregroundStyle(BrandColor.textMuted)
                            }
                        }
                        .tint(BrandColor.accent)
                        .disabled(consentWorking)

                        if let consentError {
                            Text(consentError)
                                .font(BrandFont.body(12))
                                .foregroundStyle(BrandColor.ember)
                        }
                    }
                }
            }
        }
    }

    private var proFirstName: String {
        let name = booking.professional?.displayName ?? "your pro"
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    private func setConsent(_ granted: Bool) async {
        consentWorking = true
        consentError = nil
        consentLocal = granted   // optimistic
        defer { consentWorking = false }
        do {
            let result = try await session.client.bookings.setMediaConsent(
                bookingId: booking.id, granted: granted
            )
            consentLocal = result
            session.signalRefresh()
        } catch let error as APIError {
            consentLocal = !granted   // revert
            consentError = error.userMessage
        } catch {
            consentLocal = !granted
            consentError = "Couldn’t update that. Please try again."
        }
    }

    // MARK: - Manage (reschedule / cancel)

    @ViewBuilder
    private var manageCard: some View {
        if isManageable {
            VStack(spacing: 10) {
                Button {
                    Task { await beginReschedule() }
                } label: {
                    Group {
                        if loadingReschedule {
                            ProgressView().tint(BrandColor.accent)
                        } else {
                            Label("Reschedule", systemImage: "calendar.badge.clock")
                                .font(BrandFont.body(16, .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .foregroundStyle(BrandColor.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(BrandColor.textMuted.opacity(0.3), lineWidth: 1)
                    )
                }
                .disabled(loadingReschedule || cancelling)

                Button {
                    showCancelConfirm = true
                } label: {
                    Group {
                        if cancelling {
                            ProgressView().tint(BrandColor.ember)
                        } else {
                            Text("Cancel appointment").font(BrandFont.body(16, .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .foregroundStyle(BrandColor.ember)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(BrandColor.ember.opacity(0.4), lineWidth: 1)
                    )
                }
                .disabled(cancelling || loadingReschedule)

                if let manageError {
                    Text(manageError)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.ember)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Resolve the booking's offering from the pro's profile (matching the base
    /// service) so the booking flow can re-pick a slot, then present it.
    private func beginReschedule() async {
        guard !loadingReschedule, let pro = booking.professional else { return }
        loadingReschedule = true
        manageError = nil
        defer { loadingReschedule = false }

        let baseServiceId = booking.items.first(where: { !$0.isAddOn })?.serviceId
            ?? booking.items.first?.serviceId

        do {
            let profile = try await session.client.profiles.professional(id: pro.id)
            let offering = profile.offerings.first(where: { $0.serviceId == baseServiceId })
                ?? profile.offerings.first(where: { $0.name == booking.display.baseName })

            guard let offering else {
                manageError = "This service isn’t open for self-rescheduling. Message your pro to change the time."
                return
            }

            rescheduleSheet = RescheduleContext(
                offering: offering,
                professionalId: pro.id,
                proName: pro.displayName,
                locationType: (booking.locationType ?? "SALON").uppercased() == "MOBILE"
                    ? "MOBILE" : "SALON"
            )
        } catch let error as APIError {
            manageError = error.userMessage
        } catch {
            manageError = "Couldn’t load times to reschedule. Try again."
        }
    }

    private func cancelBooking() async {
        guard !cancelling else { return }
        cancelling = true
        manageError = nil
        defer { cancelling = false }
        do {
            _ = try await session.client.booking.cancel(
                bookingId: booking.id
            )
            cancelledLocally = true
            session.signalRefresh()
            await onDecision()
            dismiss()
        } catch let error as APIError {
            manageError = error.userMessage
        } catch {
            manageError = "Couldn’t cancel the appointment. Try again."
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

    // MARK: - Rebook (pro proposed a next appointment)

    private var rebookCard: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.plus").foregroundStyle(BrandColor.accent)
                    Text("Your pro proposed your next appointment")
                        .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                }
                if let when = booking.rebookProposedFor {
                    Text(Wire.dateTime(when, timeZone: booking.timeZone))
                        .font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
                }
                Text("Confirm to book it, or decline and your pro can suggest another time.")
                    .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)

                Button { Task { await decideRebook(confirm: true) } } label: {
                    rebookActionLabel("Confirm appointment", filled: true)
                }
                .disabled(decidingRebook)

                Button { Task { await decideRebook(confirm: false) } } label: {
                    rebookActionLabel("Decline", filled: false)
                }
                .disabled(decidingRebook)

                if let rebookError {
                    Text(rebookError)
                        .font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func rebookActionLabel(_ title: String, filled: Bool) -> some View {
        Group {
            if decidingRebook { ProgressView().tint(filled ? BrandColor.onAccent : BrandColor.accent) }
            else { Text(title).font(BrandFont.body(16, .semibold)) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 14)
        .foregroundStyle(filled ? BrandColor.onAccent : BrandColor.ember)
        .background(filled ? BrandColor.accent : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(filled ? Color.clear : BrandColor.ember.opacity(0.4), lineWidth: 1))
    }

    private func decideRebook(confirm: Bool) async {
        guard !decidingRebook else { return }
        decidingRebook = true
        rebookError = nil
        defer { decidingRebook = false }
        do {
            try await session.client.bookings.decideRebook(bookingId: booking.id, confirm: confirm)
            rebookDecidedLocally = true // hide the card; the new booking shows in Appointments
            session.signalRefresh()
            await onDecision()
        } catch let error as APIError {
            rebookError = error.userMessage
        } catch {
            rebookError = "Couldn’t update that. Please try again."
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
