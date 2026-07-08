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
import UIKit

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
    /// The before/after shot currently open full-screen (tap a thumbnail).
    @State private var viewingMedia: FullscreenMedia?
    /// Manual-collectable payment methods (from the pro's payment settings) +
    /// the chosen one — drive the wrap-up "Mark as paid" control.
    @State private var paymentMethods: [ProManualPaymentMethod] = []
    @State private var selectedMethod: String = ""
    @State private var markPaidError: String?
    @State private var confirmPaymentError: String?
    /// Phase D: the wrap-up "photographer's review" of the before/after set
    /// (Claude vision via POST /pro/camera/set-critique; consent-gated).
    @State private var critique: ProSetCritique?
    @State private var critiqueLoading = false
    @State private var critiqueError: String?
    @State private var showCritiqueConsent = false

    private struct CaptureSelection: Identifiable {
        let phase: MediaPhase
        var id: String { phase.rawValue }
    }

    private var beforeCount: Int { media.filter { $0.phase == .before }.count }
    private var afterCount: Int { media.filter { $0.phase == .after }.count }

    /// "Before" photos (capture order) the AFTER camera ghosts as onion-skin so the
    /// after shots line up with the before — only IMAGE rows, not video clips.
    private var beforeReferenceURLs: [URL] { imageURLs(.before) }
    private var afterImageURLs: [URL] { imageURLs(.after) }

    private func imageURLs(_ phase: MediaPhase) -> [URL] {
        media
            .filter { $0.phase == phase && $0.mediaType == .image }
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { $0.displayUrl.flatMap(URL.init(string:)) }
    }

    private struct ComparePair: Identifiable {
        let before: URL; let after: URL
        var id: String { before.absoluteString + "|" + after.absoluteString }
    }

    /// Before/after pairs in capture order (the camera shoots both in guide order),
    /// for the comparison slider.
    private var comparisonPairs: [ComparePair] {
        zip(beforeReferenceURLs, afterImageURLs).map { ComparePair(before: $0, after: $1) }
    }

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
            ProCapturePhotosView(bookingId: bookingId, phase: selection.phase,
                                 serviceName: detail?.baseItem?.serviceName,
                                 referenceURLs: selection.phase == .after ? beforeReferenceURLs : [])
        }
        .fullScreenCover(item: $viewingMedia) { item in
            MediaFullscreenViewer(media: item) { viewingMedia = nil }
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

        proofCard(state)
    }

    /// "Consultation proof recorded" card (web `ProofCard`) — shown once a remote
    /// or in-person decision exists. Decision · method · recorded-at.
    @ViewBuilder
    private func proofCard(_ state: ProSessionState) -> some View {
        if let proof = state.consultation?.proof {
            BrandSurface {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Consultation proof recorded")
                        .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    proofRow("Decision", proof.decisionLabel)
                    proofRow("Method", proof.methodLabel)
                    if let actedAt = proof.actedAt {
                        proofRow("Recorded", Wire.dateTime(actedAt, timeZone: detail?.timeZone))
                    }
                }
            }
        }
    }

    private func proofRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
            Spacer()
            Text(value).font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
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

        proofCard(state)
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
                            // Record an in-person payment when nothing's collected yet —
                            // unless the client already attested an off-platform payment
                            // (AWAITING_CONFIRMATION), in which case the pro confirms receipt.
                            if item.key == .payment && !item.done {
                                if state.checkout?.isAwaitingConfirmation == true {
                                    confirmPaymentControl()
                                } else {
                                    markPaidControl()
                                }
                            }
                        }
                    }
                }
            }

            photoSection(title: "After photos", count: afterCount, phase: .after, primary: false)

            beforeAfterSection()

            critiqueSection()

            aftercareLink("Aftercare", primary: true)

            Text(checklist.helpText).font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
        }
    }

    /// Before & after comparison slider(s) — the transformation payoff. Paged when
    /// there's more than one matched pair. Hidden until at least one pair exists.
    @ViewBuilder
    private func beforeAfterSection() -> some View {
        if !comparisonPairs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Before & after").font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                TabView {
                    ForEach(comparisonPairs) { pair in
                        BeforeAfterCompareView(beforeURL: pair.before, afterURL: pair.after)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: comparisonPairs.count > 1 ? .automatic : .never))
                .frame(height: 412)
            }
        }
    }

    // MARK: - Photographer's review (Phase D — Claude vision set critique)

    /// The wrap-up "photographer's review" card: what's strong, what to retake
    /// while the client is still in the chair, what's portfolio-worthy. The
    /// set leaves the device only after explicit consent; the server analyzes
    /// in-flight and stores nothing. Free with a daily cap (server-enforced).
    private func critiqueSection() -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(BrandColor.gold)
                    Text("Photographer’s review").font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                }

                if let result = critique {
                    critiqueResult(result)
                } else if critiqueLoading {
                    HStack(spacing: 10) {
                        ProgressView().tint(BrandColor.accent)
                        Text("Reviewing your set…").font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                } else {
                    Text("A shot-by-shot read of this set — what to publish, what to retake while they’re still in the chair.")
                        .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                    Button { requestCritique() } label: {
                        Text("Review my set").font(BrandFont.body(14, .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(BrandColor.bgSecondary)
                            .foregroundStyle(BrandColor.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    if let critiqueError {
                        Text(critiqueError).font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.ember)
                    }
                    Text(CameraVisionConsent.critiqueDisclosure)
                        .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                }
            }
        }
        .confirmationDialog("Review with AI?", isPresented: $showCritiqueConsent,
                            titleVisibility: .visible) {
            Button("Review photos") {
                CameraVisionConsent.granted = true
                startCritique()
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(CameraVisionConsent.critiqueDisclosure)
        }
    }

    @ViewBuilder
    private func critiqueResult(_ result: ProSetCritique) -> some View {
        if !result.overall.isEmpty {
            Text(result.overall).font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textPrimary)
        }
        ForEach(result.strengths, id: \.self) { strength in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                    .foregroundStyle(BrandColor.emerald).padding(.top, 2)
                Text(strength).font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
        ForEach(result.photos) { note in
            critiquePhotoRow(note)
        }
        Button { requestCritique() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                Text("Review again").font(BrandFont.body(12, .semibold))
            }
            .foregroundStyle(BrandColor.textSecondary)
        }
        .disabled(critiqueLoading)
    }

    private func critiquePhotoRow(_ note: ProSetCritiquePhotoNote) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let item = media.first(where: { $0.id == note.id }),
               let urlString = item.displayThumbUrl ?? item.displayUrl,
               let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    BrandColor.bgSecondary
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                critiqueVerdictChip(note.verdict)
                if !note.note.isEmpty {
                    Text(note.note).font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                if let tip = note.retakeTip, !tip.isEmpty {
                    Text(tip).font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.accent)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Verdicts arrive as plain strings (forward-compat) — unknown ones render
    /// neutrally instead of breaking the card.
    private func critiqueVerdictChip(_ verdict: String) -> some View {
        let label: String, icon: String, color: Color
        switch verdict {
        case "portfolio": (label, icon, color) = ("Portfolio-worthy", "sparkles", BrandColor.gold)
        case "retake": (label, icon, color) = ("Retake", "arrow.counterclockwise", BrandColor.ember)
        case "keep": (label, icon, color) = ("Keep", "checkmark", BrandColor.emerald)
        default: (label, icon, color) = (verdict.capitalized, "photo", BrandColor.textMuted)
        }
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(label).font(BrandFont.mono(10)).tracking(0.5)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    private func requestCritique() {
        critiqueError = nil
        if CameraVisionConsent.granted {
            startCritique()
        } else {
            showCritiqueConsent = true
        }
    }

    private func startCritique() {
        guard !critiqueLoading else { return }
        critiqueLoading = true
        Task {
            defer { critiqueLoading = false }
            do {
                let request = try await buildCritiqueRequest()
                critique = try await session.client.proCamera.setCritique(request)
            } catch let error as CritiqueBuildError {
                critiqueError = error.message
            } catch let error as APIError {
                critiqueError = error.userMessage
            } catch {
                critiqueError = "Couldn’t review the set. Please try again."
            }
        }
    }

    private struct CritiqueBuildError: Error {
        let message = "Couldn’t load the photos to review — check your connection."
    }

    /// The set Claude reviews: every AFTER image plus BEFOREs while there's
    /// room (cap 10, newest kept), in capture order so before→after reads
    /// naturally. Each is downloaded from its signed URL, downscaled, and
    /// inlined — the transient analysis payload never enters the media pipeline.
    private func buildCritiqueRequest() async throws -> ProSetCritiqueRequest {
        func images(_ phase: MediaPhase) -> [ProBookingMediaItem] {
            media
                .filter { $0.phase == phase && $0.mediaType == .image }
                .sorted { $0.createdAt < $1.createdAt }
        }
        let maxPhotos = 10
        let afters = Array(images(.after).suffix(maxPhotos))
        let befores = Array(images(.before).suffix(max(0, maxPhotos - afters.count)))

        var photos: [ProSetCritiqueRequest.Photo] = []
        for item in befores + afters {
            // Bounded decode — these are ORIGINAL uploads (full-sensor stills);
            // a plain UIImage(data:) decode of each would spike ~100 MB apiece.
            guard let urlString = item.displayUrl, let url = URL(string: urlString),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = await ImageDownsample.thumbnail(from: data, maxPixel: 1024),
                  let payload = CameraVisionPayload.imagePayload(
                      image, maxDimension: 1024, quality: 0.6)
            else { continue }
            photos.append(.init(id: item.id,
                                phase: item.phase == .before ? "BEFORE" : "AFTER",
                                image: payload))
        }
        guard !photos.isEmpty else { throw CritiqueBuildError() }
        return ProSetCritiqueRequest(photos: photos,
                                     serviceName: detail?.baseItem?.serviceName)
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

    /// Confirm receipt of an off-platform payment the client already marked as sent
    /// (web `ConfirmPaymentReceivedButton`). Confirming closes out this booking AND
    /// auto-approves any aftercare next appointment coupled to the payment.
    @ViewBuilder
    private func confirmPaymentControl() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The client marked this payment as sent. Confirm once you’ve received it to close out the booking.")
                .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { Task { await confirmPayment() } } label: {
                Text(working ? "Confirming…" : "Confirm payment received")
                    .font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.onAccent)
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(BrandColor.emerald)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .disabled(working)

            Text("This also approves the next booking the client requested.")
                .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)

            if let confirmPaymentError {
                Text(confirmPaymentError).font(BrandFont.body(11)).foregroundStyle(BrandColor.ember)
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
        Button {
            viewingMedia = FullscreenMedia.session(item)
        } label: {
            ZStack {
                BrandColor.bgSecondary
                if let urlString = item.displayThumbUrl, let url = URL(string: urlString) {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
                        ProgressView().tint(BrandColor.accent)
                    }
                } else {
                    Image(systemName: "photo").foregroundStyle(BrandColor.textMuted)
                }
                if item.mediaType == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 3)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
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

    private func confirmPayment() async {
        guard !working else { return }
        confirmPaymentError = nil
        working = true
        defer { working = false }
        do {
            try await session.client.proBookings.confirmPayment(bookingId: bookingId)
            session.signalRefresh()
            await load()
        } catch let error as APIError {
            confirmPaymentError = error.userMessage
        } catch {
            confirmPaymentError = "Could not confirm payment. Check your connection and try again."
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
