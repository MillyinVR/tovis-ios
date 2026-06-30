// Pro session hub — the live-appointment state machine the footer center button
// opens (web `app/pro/bookings/[id]/session/page.tsx`). The server resolves the
// effective step; `ProSessionFlow.screenKey` maps it to one of five screens, each
// rendered with the persistent 4-step rail:
//   Consultation → Waiting + Before photos → Service in progress → Wrap-up → Done.
// Data: `GET /session/state` (the spine) + `GET /pro/bookings/[id]` (display copy
// + initial consultation line items) + the booking media list (before/after counts).
import Combine
import SwiftUI
import TovisKit

struct ProSessionHubView: View {
    @Environment(SessionModel.self) private var session
    let bookingId: String

    private enum Phase {
        case loading
        case loaded(ProSessionState)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var detail: ProBookingDetail?
    @State private var media: [ProBookingMediaItem] = []
    @State private var working = false
    @State private var actionError: String?
    @State private var capturing: CaptureSelection?
    /// Manual-collectable payment methods (from the pro's payment settings) +
    /// the chosen one — drive the wrap-up "Mark as paid" control.
    @State private var paymentMethods: [ProManualPaymentMethod] = []
    @State private var selectedMethod: String = ""
    @State private var markPaidError: String?

    private struct CaptureSelection: Identifiable {
        let phase: MediaPhase
        var id: String { phase.rawValue }
    }

    private var beforeCount: Int { media.filter { $0.phase == .before }.count }
    private var afterCount: Int { media.filter { $0.phase == .after }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 80)
                case let .failed(message):
                    errorState(message)
                case let .loaded(state):
                    content(state)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .onChange(of: session.refreshTick) { Task { await loadMedia() } }
        .fullScreenCover(item: $capturing, onDismiss: { Task { await reloadAfterCapture() } }) { selection in
            ProCapturePhotosView(bookingId: bookingId, phase: selection.phase)
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Screen routing

    @ViewBuilder
    private func content(_ state: ProSessionState) -> some View {
        if state.terminal {
            terminalScreen(state)
        } else {
            let step = state.step
            SessionScreenHeader(state: state, detail: detail)
            ProSessionStepRail(effectiveStep: step)

            if let actionError {
                Text(actionError).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
            }

            switch state.screenKey {
            case .consultation:
                consultationScreen(state)
            case .waitingOnClient, .beforePhotos:
                waitingBeforeScreen(state)
            case .serviceInProgress:
                serviceInProgressScreen(state)
            case .wrapUp:
                wrapUpScreen(state)
            case .done:
                doneScreen(state)
            }
        }
    }

    // MARK: - Consultation

    @ViewBuilder
    private func consultationScreen(_ state: ProSessionState) -> some View {
        BrandSurface(tint: BrandColor.accent.opacity(0.08)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(BrandColor.accent).frame(width: 8, height: 8)
                    Text("Step 1 · Consultation").font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                }
                Text("Review services, set price, and send to the client for approval before you begin.")
                    .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
            }
        }

        HStack(spacing: 12) {
            statCard("TOTAL", totalLabel)
            statCard("DURATION", durationLabel)
        }

        if state.isConsultationRejected {
            BrandSurface(tint: BrandColor.ember.opacity(0.08)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Consultation needs changes").font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("The last decision was rejected. Update the proposal and resend it when ready.")
                        .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                }
            }
        }

        ProConsultationFormView(
            bookingId: bookingId,
            initialItems: initialConsultationItems(),
            suggestedTotal: suggestedTotal,
            onSent: { Task { await load() } },
        )

        Text("After you submit, it moves to Waiting on client.")
            .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)

        let canProceed = (state.status?.uppercased() == "ACCEPTED" || state.status?.uppercased() == "IN_PROGRESS")
            && state.isConsultationApproved
        if canProceed {
            primaryButton("Proceed to before photos") { await transition(to: .beforePhotos) }
        }
        if state.status?.uppercased() == "PENDING" {
            Text("This booking is pending. Accept it before starting the session.")
                .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
        }
    }

    // MARK: - Waiting on client + before photos (combined)

    @ViewBuilder
    private func waitingBeforeScreen(_ state: ProSessionState) -> some View {
        let approved = state.isConsultationApproved
        BrandSurface(tint: approved ? BrandColor.emerald.opacity(0.08) : BrandColor.bgSurface) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    BrandPill(
                        text: consultationStatusLabel(state),
                        tint: approved ? BrandColor.emerald : BrandColor.gold,
                    )
                    Text(approved ? "Consultation approved" : "Waiting on client")
                        .font(BrandFont.body(11, .bold)).foregroundStyle(BrandColor.textMuted)
                }
                Text(approved
                    ? "You’re approved. Finish your before photos, then continue to service."
                    : "Secure approval is required before you can start the service. While you wait, take BEFORE photos now.")
                    .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
            }
        }

        photoSection(title: "Before photos", count: beforeCount, phase: .before,
                     primary: beforeCount == 0)

        if approved {
            if beforeCount > 0 {
                primaryButton("Continue to service") { await transition(to: .serviceInProgress) }
            } else {
                Text("Add at least one before photo to continue to service.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
            }
        }

        // In-person fallback — only while pending and no proof recorded.
        if !approved && state.isConsultationPending {
            BrandSurface {
                VStack(alignment: .leading, spacing: 10) {
                    Text("In-person fallback").font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("Only use this if the client is physically present and cannot access their secure link. It will be logged honestly as in-person on pro device.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                    HStack(spacing: 10) {
                        ghostButton("Record approval", systemImage: "checkmark") { await inPersonDecision(approve: true) }
                        dangerButton("Record decline") { await inPersonDecision(approve: false) }
                    }
                }
            }
        }

        if !approved {
            ghostButton("← Back to consultation") { await transition(to: .consultation) }
        }
    }

    // MARK: - Service in progress

    @ViewBuilder
    private func serviceInProgressScreen(_ state: ProSessionState) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 6) {
                Text("ELAPSED").font(BrandFont.mono(10)).tracking(0.8).foregroundStyle(BrandColor.textMuted)
                ProSessionElapsedTimer(startedAtISO: state.startedAt)
                    .font(BrandFont.display(40, .semibold)).foregroundStyle(BrandColor.textPrimary)
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 11))
                    Text("Started at \(startedTimeLabel(state.startedAt)) · \(durationLabel) booked")
                        .font(BrandFont.body(12))
                }
                .foregroundStyle(BrandColor.textMuted)
            }
        }

        BrandSurface {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(beforeCount) before photos saved").font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("Ready for comparison at wrap-up").font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                Spacer()
                BrandPill(text: "SAVED", tint: BrandColor.emerald)
            }
        }

        primaryButton("Finish service") { await finishService() }
        Text("Moves to after photos").font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
    }

    // MARK: - Wrap-up (S1: read-only checklist + links; Mark Paid lands in S2)

    @ViewBuilder
    private func wrapUpScreen(_ state: ProSessionState) -> some View {
        // No after photo yet → send the pro to capture them first (web redirects).
        if afterCount == 0 {
            BrandSurface {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Capture after photos").font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("Take at least one after photo to open the wrap-up checklist.")
                        .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                }
            }
            photoSection(title: "After photos", count: afterCount, phase: .after, primary: true)
        } else {
            let checklist = ProSessionCloseout.checklist(closeoutInput(state))
            BrandSurface {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Wrap-up checklist").font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    ForEach(checklist.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            checklistRow(item)
                            // Record an in-person payment when nothing's collected yet.
                            if item.key == .payment && !item.done {
                                markPaidControl()
                            }
                        }
                    }
                }
            }

            photoSection(title: "After photos", count: afterCount, phase: .after, primary: false)

            aftercareLink("Aftercare", primary: true)

            Text(checklist.helpText).font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
        }
    }

    /// A push link to the aftercare authoring screen; reloads the hub on send.
    private func aftercareLink(_ title: String, primary: Bool) -> some View {
        NavigationLink {
            ProAftercareAuthorView(bookingId: bookingId, onSent: { Task { await load() } })
        } label: {
            Text(title).font(BrandFont.body(16, .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(primary ? BrandColor.accent : BrandColor.bgSecondary)
                .foregroundStyle(primary ? BrandColor.onAccent : BrandColor.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func checklistRow(_ item: ProSessionCloseoutItem) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(item.done ? BrandColor.emerald.opacity(0.15) : BrandColor.bgSecondary)
                Image(systemName: item.done ? "checkmark" : "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(item.done ? BrandColor.emerald : BrandColor.textMuted)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text(item.subtitle).font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
            }
            Spacer()
            BrandPill(text: item.done ? "Done" : "To do",
                      tint: item.done ? BrandColor.emerald : BrandColor.gold)
        }
    }

    /// The in-person "Mark as paid" control (web `MarkPaidButton`): a method
    /// picker + button, or an empty-state when no method is enabled.
    @ViewBuilder
    private func markPaidControl() -> some View {
        if paymentMethods.isEmpty {
            Text("Turn on a payment method in your payment settings to record an in-person payment here.")
                .font(BrandFont.body(11)).foregroundStyle(BrandColor.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Picker("Payment method", selection: $selectedMethod) {
                        ForEach(paymentMethods) { method in
                            Text(method.label).tag(method.value)
                        }
                    }
                    .pickerStyle(.menu).tint(BrandColor.accent)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(BrandColor.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Button { Task { await markPaid() } } label: {
                        Text(working ? "Recording…" : "Mark as paid")
                            .font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.onAccent)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(BrandColor.emerald)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .disabled(working || selectedMethod.isEmpty)
                }
                if let markPaidError {
                    Text(markPaidError).font(BrandFont.body(11)).foregroundStyle(BrandColor.ember)
                }
            }
        }
    }

    // MARK: - Done / Terminal

    @ViewBuilder
    private func doneScreen(_ state: ProSessionState) -> some View {
        BrandSurface(tint: BrandColor.emerald.opacity(0.08)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(BrandColor.emerald).frame(width: 8, height: 8)
                    Text("All set").font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                }
                Text("This session is complete. The client can keep their aftercare summary.")
                    .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
            }
        }
        aftercareLink("Open aftercare", primary: true)
    }

    @ViewBuilder
    private func terminalScreen(_ state: ProSessionState) -> some View {
        let isCancelled = state.status?.uppercased() == "CANCELLED"
        SessionScreenHeader(state: state, detail: detail)
        BrandSurface(tint: (isCancelled ? BrandColor.ember : BrandColor.emerald).opacity(0.08)) {
            VStack(alignment: .leading, spacing: 6) {
                Text(isCancelled ? "This booking is cancelled." : "This booking is completed.")
                    .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text(isCancelled ? "Nothing to do here." : "The session has already been finalized.")
                    .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
            }
        }
    }

    // MARK: - Shared pieces

    private func statCard(_ label: String, _ value: String) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(BrandFont.mono(10)).tracking(0.8).foregroundStyle(BrandColor.textMuted)
                Text(value).font(BrandFont.display(20, .semibold)).foregroundStyle(BrandColor.textPrimary)
            }
        }
    }

    @ViewBuilder
    private func photoSection(title: String, count: Int, phase: MediaPhase, primary: Bool) -> some View {
        let shots = media.filter { $0.phase == phase }
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        Text("\(count) captured").font(BrandFont.body(12))
                    }
                    .foregroundStyle(BrandColor.textMuted)
                }
                if !shots.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(shots) { thumbnail($0) } }
                    }
                }
                Button { capturing = CaptureSelection(phase: phase) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.fill").font(.system(size: 13, weight: .semibold))
                        Text(count > 0 ? "Add more \(title.lowercased())" : "Take \(title.lowercased())")
                            .font(BrandFont.body(14, .semibold))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(primary ? BrandColor.accent : BrandColor.accent.opacity(0.12))
                    .foregroundStyle(primary ? BrandColor.onAccent : BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ item: ProBookingMediaItem) -> some View {
        ZStack {
            BrandColor.bgSecondary
            if let urlString = item.displayThumbUrl, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
                    ProgressView().tint(BrandColor.accent)
                }
            } else {
                Image(systemName: "photo").foregroundStyle(BrandColor.textMuted)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func primaryButton(_ title: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            HStack {
                if working { ProgressView().tint(BrandColor.onAccent) }
                Text(title).font(BrandFont.body(16, .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(BrandColor.accent).foregroundStyle(BrandColor.onAccent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(working)
    }

    private func ghostButton(_ title: String, systemImage: String? = nil, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(BrandFont.body(14, .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(BrandColor.bgSecondary).foregroundStyle(BrandColor.textPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(working)
    }

    private func dangerButton(_ title: String, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Text(title).font(BrandFont.body(14, .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(BrandColor.ember.opacity(0.12)).foregroundStyle(BrandColor.ember)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(working)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 70)
    }

    // MARK: - Derived display copy

    private var totalLabel: String {
        guard let detail else { return "—" }
        let text = detail.totalAmount ?? detail.subtotalSnapshot
        return text.map { "$\($0)" } ?? "—"
    }
    private var suggestedTotal: String? {
        detail?.totalAmount ?? detail?.subtotalSnapshot
    }
    private var durationMinutes: Int {
        guard let detail else { return 0 }
        if detail.totalDurationMinutes > 0 { return detail.totalDurationMinutes }
        return detail.serviceItems.reduce(0) { $0 + max(0, $1.durationMinutesSnapshot) }
    }
    private var durationLabel: String {
        durationMinutes > 0 ? "\(durationMinutes) min" : "Duration TBD"
    }

    private func consultationStatusLabel(_ state: ProSessionState) -> String {
        switch state.consultation?.status?.uppercased() {
        case "PENDING": return "Pending"
        case "APPROVED": return "Approved"
        case "REJECTED": return "Rejected"
        default: return "None"
        }
    }

    private func startedTimeLabel(_ iso: String?) -> String {
        guard let iso else { return "—" }
        return Wire.dateTime(iso, timeZone: detail?.timeZone)
    }

    /// Initial consultation line items from the booking's services (web
    /// `buildInitialConsultationItems`).
    private func initialConsultationItems() -> [ProConsultationLineItem] {
        guard let detail else { return [] }
        return detail.serviceItems.enumerated().map { index, item in
            let itemType = item.itemType.uppercased() == "ADD_ON"
                ? "ADD_ON" : (index == 0 ? "BASE" : (item.isAddOn ? "ADD_ON" : "BASE"))
            return ProConsultationLineItem(
                bookingServiceItemId: item.id,
                offeringId: item.offeringId,
                serviceId: item.serviceId,
                itemType: itemType,
                label: item.serviceName.isEmpty ? "Service" : item.serviceName,
                categoryName: nil,
                price: item.priceSnapshot ?? "",
                durationMinutes: item.durationMinutesSnapshot > 0 ? String(item.durationMinutesSnapshot) : "",
                notes: "",
                sortOrder: item.sortOrder,
                source: "BOOKING",
            )
        }
    }

    private func closeoutInput(_ state: ProSessionState) -> ProSessionCloseoutInput {
        ProSessionCloseoutInput(
            afterCount: afterCount,
            hasAfterPhoto: afterCount > 0,
            hasAftercareDraft: state.aftercare?.hasDraft ?? false,
            hasFinalizedAftercare: state.aftercare?.isSent ?? false,
            hasPaymentCollected: state.checkout?.paymentCollectedAt != nil,
            hasCheckoutClosed: state.checkout?.isClosed ?? false,
            hasConsultationApproved: state.isConsultationApproved,
        )
    }

    // MARK: - Actions

    private func load() async {
        do {
            async let stateTask = session.client.proSession.state(bookingId: bookingId)
            async let detailTask = try? session.client.proBookings.detail(bookingId: bookingId)
            let state = try await stateTask
            detail = await detailTask
            phase = .loaded(state)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load this session.")
        }
        await loadMedia()
        await loadPaymentMethods()
    }

    private func loadMedia() async {
        media = (try? await session.client.proMedia.list(bookingId: bookingId)) ?? media
    }

    private func reloadAfterCapture() async {
        await loadMedia()
        await load()
    }

    private func transition(to step: SessionStep) async {
        await run { try await session.client.proSession.advanceStep(bookingId: bookingId, to: step.rawValue) }
    }

    private func finishService() async {
        await run { _ = try await session.client.proSession.finish(bookingId: bookingId) }
    }

    private func inPersonDecision(approve: Bool) async {
        await run { try await session.client.proSession.recordInPersonDecision(bookingId: bookingId, approve: approve) }
    }

    private func markPaid() async {
        guard !selectedMethod.isEmpty else { return }
        markPaidError = nil
        working = true
        defer { working = false }
        do {
            try await session.client.proBookings.markPaid(bookingId: bookingId, selectedPaymentMethod: selectedMethod)
            session.signalRefresh()
            await load()
        } catch let error as APIError {
            markPaidError = error.userMessage
        } catch {
            markPaidError = "Could not record payment. Check your connection and try again."
        }
    }

    private func loadPaymentMethods() async {
        guard let settings = try? await session.client.proProfile.paymentSettings() else { return }
        paymentMethods = settings.manualCollectableMethods
        if selectedMethod.isEmpty { selectedMethod = paymentMethods.first?.value ?? "" }
    }

    /// Run a session write, then reload + refresh the footer.
    private func run(_ op: @escaping () async throws -> Void) async {
        working = true
        actionError = nil
        defer { working = false }
        do {
            try await op()
            session.signalRefresh()
            await load()
        } catch let error as APIError {
            actionError = error.userMessage
        } catch {
            actionError = "Something went wrong."
        }
    }
}

/// The session-screen header — back affordance is the nav stack; shows the kicker
/// (step state), service title, and client · time · duration subtitle.
private struct SessionScreenHeader: View {
    let state: ProSessionState
    let detail: ProBookingDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kicker)
                .font(BrandFont.mono(11)).tracking(1.2).textCase(.uppercase)
                .foregroundStyle(kickerTone)
            Text(detail?.title ?? "Session")
                .font(BrandFont.display(24, .semibold)).foregroundStyle(BrandColor.textPrimary)
            if let subtitle { Text(subtitle).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kicker: String {
        if state.terminal {
            return state.status?.uppercased() == "CANCELLED" ? "Cancelled" : "Completed"
        }
        switch state.screenKey {
        case .consultation: return "◆ Session active"
        case .waitingOnClient, .beforePhotos:
            return state.isConsultationApproved ? "◆ Consultation approved" : "⏳ Awaiting approval"
        case .serviceInProgress: return "◆ In progress"
        case .wrapUp: return "Wrap-up · Aftercare"
        case .done: return "◆ Done"
        }
    }

    private var kickerTone: Color {
        switch state.screenKey {
        case .waitingOnClient, .beforePhotos:
            return state.isConsultationApproved ? BrandColor.emerald : BrandColor.gold
        case .done: return BrandColor.emerald
        default: return BrandColor.textMuted
        }
    }

    private var subtitle: String? {
        guard let detail else { return nil }
        let when = Wire.dateTime(detail.scheduledFor, timeZone: detail.timeZone)
        let duration = detail.totalDurationMinutes > 0 ? "\(detail.totalDurationMinutes) min" : "Duration TBD"
        return "\(detail.client.fullName) · \(when) · \(duration)"
    }
}

/// A live elapsed-time counter for the service-in-progress screen (web `ElapsedTimer`).
private struct ProSessionElapsedTimer: View {
    let startedAtISO: String?
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(elapsed)
            .monospacedDigit()
            .onReceive(tick) { now = $0 }
    }

    private var elapsed: String {
        guard let iso = startedAtISO, let start = Wire.date(iso) else { return "00:00" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
