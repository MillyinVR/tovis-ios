// Pro session hub — the live-appointment state machine the footer center button
// opens (web `app/pro/bookings/[id]/session/page.tsx`). The server resolves the
// effective step; `ProSessionFlow.screenKey` maps it to one of five screens, each
// rendered with the persistent 4-step rail:
//   Consultation → Waiting + Before photos → Service in progress → Wrap-up → Done.
// Data: `GET /session/state` (the spine) + `GET /pro/bookings/[id]` (display copy
// + initial consultation line items) + the booking media list (before/after counts).
import Combine
import PhotosUI
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
    /// Booking-scoped media-use consent (`clientUseConsent` on the media list).
    /// When true the client approved featuring this session's photos publicly, so
    /// the pro's publish action is unlocked; surfaced passively so it isn't a
    /// surprise at publish time. Defaults false (also the pre-deploy fallback).
    @State private var clientUseConsent = false
    @State private var working = false
    @State private var actionError: String?
    /// Which before/after pair the comparison pager is showing — the one the
    /// "Publish this transformation" button acts on.
    @State private var comparisonPage = 0
    @State private var capturing: CaptureSelection?
    /// "Upload from library" — which phase the picked photos belong to, the
    /// picker's presentation flag, and what came back.
    ///
    /// This door exists on the SESSION screen, not only inside the camera's
    /// tools drawer, because that is where a pro looks for it: the camera tray
    /// version is unreachable without first opening a camera they may not want.
    @State private var importPhase: MediaPhase?
    @State private var showLibraryPicker = false
    @State private var importItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var importMessage: String?
    /// The durable uploader, read only to show the pro what's still outstanding.
    private var uploads: SessionUploadQueue { .shared }
    /// The before/after shot currently open full-screen (tap a thumbnail).
    @State private var viewingMedia: FullscreenMedia?
    /// Manual-collectable payment methods (from the pro's payment settings) +
    /// the chosen one — drive the wrap-up "Mark as paid" control.
    @State private var paymentMethods: [ProManualPaymentMethod] = []
    @State private var selectedMethod: String = ""
    @State private var markPaidError: String?
    @State private var confirmPaymentError: String?
    /// Undo (reopen) of a mistaken manual mark-paid / waive — M9 follow-up.
    @State private var reopenError: String?
    @State private var showReopenConfirm = false
    /// Phase D: the wrap-up "photographer's review" of the before/after set
    /// (Claude vision via POST /pro/camera/set-critique; consent-gated).
    @State private var critique: ProSetCritique?
    @State private var critiqueLoading = false
    @State private var critiqueError: String?
    /// True when the last critique failure was the monthly image quota (403) —
    /// drives the "See membership options" upgrade route below the error.
    @State private var critiqueOffersUpgrade = false
    @State private var showCritiqueConsent = false
    /// K15/K17-A: the forms this appointment needs that the client has not
    /// signed, off `GET …/session/state`'s sibling field. Empty is the common
    /// case (and the only representation of "nothing outstanding" — the route
    /// omits the key rather than sending `[]`).
    @State private var unsignedConsentForms: [ProUnsignedConsentForm.Display] = []
    /// Which form's link is in flight, which ones this screen has already sent,
    /// and the server's own sentence if a send was refused.
    @State private var sendingConsentFormId: String?
    @State private var sentConsentFormIds: Set<String> = []
    @State private var consentSendError: String?

    private struct CaptureSelection: Identifiable {
        let phase: MediaPhase
        var id: String { phase.rawValue }
    }

    private var beforeCount: Int { media.filter { $0.phase == .before }.count }
    private var afterCount: Int { media.filter { $0.phase == .after }.count }

    /// "Before" photos (capture order) the AFTER camera ghosts as onion-skin so the
    /// after shots line up with the before — only IMAGE rows, not video clips.
    private var beforeReferenceURLs: [URL] { imageURLs(.before) }

    /// IMAGE rows for a phase in capture order — the shared basis for both the
    /// onion-skin reference URLs and the before/after comparison pairs. Filtered to
    /// rows that actually have a displayable URL so the pair zip stays aligned.
    private func imageItems(_ phase: MediaPhase) -> [ProBookingMediaItem] {
        media
            .filter { $0.phase == phase && $0.mediaType == .image && $0.displayUrl != nil }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func imageURLs(_ phase: MediaPhase) -> [URL] {
        imageItems(phase).compactMap { $0.displayUrl.flatMap(URL.init(string:)) }
    }

    /// A matched before/after. Carries the underlying media items (not just URLs) so
    /// the wrap-up can publish the exact pair the pro is viewing: the "after" is the
    /// asset featured into the portfolio, the "before" pins its comparison partner.
    private struct ComparePair: Identifiable {
        let beforeItem: ProBookingMediaItem
        let afterItem: ProBookingMediaItem
        let before: URL
        let after: URL
        var id: String { beforeItem.id + "|" + afterItem.id }
    }

    /// Before/after pairs in capture order (the camera shoots both in guide order),
    /// for the comparison slider.
    private var comparisonPairs: [ComparePair] {
        zip(imageItems(.before), imageItems(.after)).compactMap { before, after in
            guard let beforeURL = before.displayUrl.flatMap(URL.init(string:)),
                  let afterURL = after.displayUrl.flatMap(URL.init(string:)) else { return nil }
            return ComparePair(beforeItem: before, afterItem: after, before: beforeURL, after: afterURL)
        }
    }

    /// The "before" this shot is paired with, when it is an AFTER that has one.
    /// Reuses `comparisonPairs` — the same pairing the wrap-up publishes — so the
    /// diptych a pro exports is the diptych their portfolio shows.
    private func pairedBefore(for item: ProBookingMediaItem) -> ProBookingMediaItem? {
        comparisonPairs.first { $0.afterItem.id == item.id }?.beforeItem
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
        // A live tick means the CLIENT just acted — approved or declined the
        // consultation, signed a consent form, answered the confirmation. All of
        // that lives in the session state, not in the media list, so reloading
        // only media left the pro looking at a stale screen until they backed
        // out and came in again. `silent` keeps the last good state on a
        // transient failure rather than swapping the screen for an error card.
        .onChange(of: session.refreshTick) { Task { await load(silent: true) } }
        .fullScreenCover(item: $capturing, onDismiss: { Task { await reloadAfterCapture() } }) { selection in
            ProCapturePhotosView(destination: .session(bookingId: bookingId, phase: selection.phase),
                                 serviceName: detail?.baseItem?.serviceName,
                                 referenceURLs: selection.phase == .after ? beforeReferenceURLs : [],
                                 // Photos this phase ALREADY has. Without it the
                                 // camera would re-ask for the required shot every
                                 // time it reopens on a phase that's already covered.
                                 alreadyCaptured: selection.phase == .before ? beforeCount : afterCount)
        }
        .fullScreenCover(item: $viewingMedia) { item in
            MediaFullscreenViewer(media: item) { viewingMedia = nil }
        }
        .photosPicker(
            isPresented: $showLibraryPicker,
            selection: $importItems,
            maxSelectionCount: 10,
            matching: .images
        )
        .onChange(of: importItems) { _, items in
            guard !items.isEmpty, let phase = importPhase else { return }
            importItems = []
            Task { await importFromLibrary(items, phase: phase) }
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

            unsignedConsentBanner(state)

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

    // MARK: - Unsigned consent forms (K15 / K17-A)

    /// What the pro sees at session start when this appointment's services
    /// require a form the client has not signed.
    ///
    /// 🔴 It WARNS. There is no "you cannot start" here and no disabled control —
    /// blocking a real appointment over an unsigned waiver on the day a pro sets
    /// their first requirement is exactly what K15 refused. The pro decides: send
    /// the link now, take it on paper, or carry on. Web's banner says so in as
    /// many words and this repeats it, because a warning with no stated
    /// consequence reads as one.
    ///
    /// 🔴 NOT gated on anything resembling `significant`. The calendar chip's
    /// gate goes quiet once `scheduledFor <= now`, which at session start is true
    /// by definition — the same gate here would blank the warning at the exact
    /// moment it is worth the most. The SCREEN carries the decision instead:
    /// shown on the pre-service screens (and while the service runs, where the
    /// pro can still get a signature), never on wrap-up, done, or a terminal
    /// booking, where signing beforehand is a fact nobody can act on. That is
    /// web's placement, screen for screen.
    @ViewBuilder
    private func unsignedConsentBanner(_ state: ProSessionState) -> some View {
        if !unsignedConsentForms.isEmpty, showsConsentBanner(state.screenKey) {
            BrandSurface(tint: BrandColor.amber.opacity(0.08)) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(unsignedConsentForms.count == 1
                        ? "A form for this service is unsigned"
                        : "\(unsignedConsentForms.count) forms for this service are unsigned")
                        .font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)

                    ForEach(unsignedConsentForms) { form in
                        consentFormRow(form)
                    }

                    if let consentSendError {
                        Text(consentSendError)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.ember)
                    }

                    Text("You can start the appointment either way — this is a reminder, not a block.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
    }

    /// Web renders the banner on the CONSULTATION, WAITING_ON_CLIENT /
    /// BEFORE_PHOTOS and SERVICE_IN_PROGRESS screens and nowhere else.
    /// Deliberately a `switch` with every case spelled out rather than a `!=`
    /// list: a sixth screen added later has to make this choice on purpose.
    private func showsConsentBanner(_ screenKey: ProSessionScreenKey) -> Bool {
        switch screenKey {
        case .consultation, .waitingOnClient, .beforePhotos, .serviceInProgress:
            return true
        case .wrapUp, .done:
            return false
        }
    }

    /// One outstanding form: what it is, and the pro's one action on it.
    ///
    /// The row names the form and its kind because "which waiver?" is the pro's
    /// next question, and VoiceOver reads the two as a sentence rather than as a
    /// middle dot (`accessibilityLabel` on the display row).
    @ViewBuilder
    private func consentFormRow(_ form: ProUnsignedConsentForm.Display) -> some View {
        let sent = sentConsentFormIds.contains(form.formId)
        let sending = sendingConsentFormId == form.formId

        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(form.title)
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                if let kindLabel = form.kindLabel {
                    Text(kindLabel)
                        .font(BrandFont.body(11))
                        .foregroundStyle(BrandColor.textSecondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(form.accessibilityLabel)

            Spacer(minLength: 8)

            // The link can only be minted for a client this screen can name.
            // `ProBookingClient.id` is optional for older backends, and a send
            // with no client id has nowhere to go — so the WARNING still shows
            // and only the action is withheld.
            if let clientId = detail?.client.id, !clientId.isEmpty {
                Button {
                    Task { await sendConsentLink(clientId: clientId, form: form) }
                } label: {
                    Text(sending ? "Sending…" : (sent ? "Sent" : "Send"))
                        .font(BrandFont.body(12, .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(BrandColor.bgSecondary)
                        .foregroundStyle(sent ? BrandColor.textMuted : BrandColor.textPrimary)
                        .clipShape(Capsule())
                }
                .disabled(sending)
            }
        }
    }

    /// POST the signing link for ONE form, anchored to THIS booking.
    ///
    /// 🔴 The booking id is explicit. Omitted, the server attaches the link to
    /// the client's next upcoming appointment — which is not necessarily the one
    /// the pro is standing in: the hub can be opened from a booking detail long
    /// before that booking is next.
    ///
    /// "Sent" is a receipt for the send, NOT for a signature: the banner stays up
    /// until the client actually signs and the next load drops the row. Web makes
    /// the same distinction, and hiding the ask on send would tell the pro the
    /// thing they still need is done.
    private func sendConsentLink(clientId: String, form: ProUnsignedConsentForm.Display) async {
        guard sendingConsentFormId == nil else { return }
        sendingConsentFormId = form.formId
        consentSendError = nil
        defer { sendingConsentFormId = nil }

        do {
            try await session.client.proClients.sendConsentRequest(
                clientId: clientId, formId: form.formId, bookingId: bookingId
            )
            sentConsentFormIds.insert(form.formId)
        } catch let error as APIError {
            // The server's own sentence — it knows why (no booking to attach to,
            // a form this pro doesn't own, a client they can't view).
            consentSendError = error.userMessage
        } catch {
            consentSendError = "Couldn’t send the form."
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
            initialItems: detail?.initialConsultationItems ?? [],
            suggestedTotal: suggestedTotal,
            onSent: { Task { await load() } },
        )

        Text("After you submit, it moves to Waiting on client.")
            .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)

        if state.canProceedToBeforePhotos {
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
                        text: state.consultationStatusLabel,
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
                     primary: !ProSessionPhotoRequirement.isMet(captured: beforeCount))

        if approved {
            if ProSessionPhotoRequirement.isMet(captured: beforeCount) {
                primaryButton("Continue to service") { await transition(to: .serviceInProgress) }
            } else {
                Text(ProSessionPhotoRequirement.gateSentence(
                    .before, action: "Add", purpose: "to continue to service"))
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
                    Text("\(beforeCount) before photo\(beforeCount == 1 ? "" : "s") saved")
                        .font(BrandFont.body(14, .semibold))
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
        // No after photo yet → send the pro to capture one first (web redirects).
        if !ProSessionPhotoRequirement.isMet(captured: afterCount) {
            BrandSurface {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Capture after photos").font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(ProSessionPhotoRequirement.gateSentence(
                        .after, action: "Take", purpose: "to open the wrap-up checklist"))
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
                            if item.key == .payment {
                                if !item.done {
                                    if state.checkout?.isAwaitingConfirmation == true {
                                        confirmPaymentControl()
                                    } else {
                                        markPaidControl()
                                    }
                                } else if state.checkout?.isManuallyClosed == true {
                                    // Fat-fingered a mark-paid / waive? Undo it (M9
                                    // follow-up). Only shown for a manual close-out; a
                                    // card capture reverses via a refund.
                                    reopenControl()
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
    /// Below the pager: publish the visible pair straight into the pro's Looks feed.
    @ViewBuilder
    private func beforeAfterSection() -> some View {
        let pairs = comparisonPairs
        if !pairs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Before & after").font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                TabView(selection: $comparisonPage) {
                    ForEach(Array(pairs.enumerated()), id: \.element.id) { index, pair in
                        BeforeAfterCompareView(beforeURL: pair.before, afterURL: pair.after)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: pairs.count > 1 ? .automatic : .never))
                .frame(height: 412)

                if pairs.indices.contains(comparisonPage) {
                    publishTransformationControl(for: pairs[comparisonPage])
                }
            }
        }
    }

    /// Publish the visible before/after into the pro's public Looks feed. Three
    /// states: already published (confirmation), consent granted (the live button),
    /// or consent pending (locked, explains why). The action features the "after"
    /// asset and pins the "before" partner; the server-side share guard is the real
    /// gate — this just keeps the pro from getting their first "no" from a 403.
    @ViewBuilder
    private func publishTransformationControl(for pair: ComparePair) -> some View {
        if pair.afterItem.isFeaturedInPortfolio {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 12, weight: .semibold))
                Text("Published to your Looks").font(BrandFont.body(14, .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .foregroundStyle(BrandColor.emerald)
            .background(BrandColor.emerald.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if clientUseConsent {
            Button { Task { await publishTransformation(pair) } } label: {
                HStack(spacing: 6) {
                    if working {
                        ProgressView().tint(BrandColor.onAccent)
                    } else {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .semibold))
                    }
                    Text("Publish this transformation").font(BrandFont.body(14, .semibold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(BrandColor.accent)
                .foregroundStyle(BrandColor.onAccent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(working)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold))
                Text("Publish once the client approves sharing").font(BrandFont.body(13))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .foregroundStyle(BrandColor.textMuted)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                        if critiqueOffersUpgrade {
                            NavigationLink { ProMembershipView() } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("See membership options")
                                        .font(BrandFont.body(13, .semibold))
                                }
                                .foregroundStyle(BrandColor.accent)
                            }
                        }
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
        critiqueOffersUpgrade = false
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
            } catch {
                // Monthly quota (403) → friendly copy + upgrade route; daily cap
                // (429) → "try again tomorrow"; everything else → its message.
                let aiError = ProCameraAIError.from(error)
                critiqueError = aiError.userMessage
                critiqueOffersUpgrade = aiError.offersUpgrade
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

    /// Undo a mistaken manual mark-paid / waive (web `ReopenCheckoutButton`).
    /// Reverses the checkout record back to READY so the pro can re-collect. A
    /// confirmation dialog guards against an accidental un-collection; a live
    /// card capture never reaches here (hidden by `isManuallyClosed`) and is
    /// refused server-side regardless.
    @ViewBuilder
    private func reopenControl() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { showReopenConfirm = true } label: {
                Text(working ? "Reopening…" : "Recorded by mistake? Undo & reopen")
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
                    .underline()
            }
            .disabled(working)
            .confirmationDialog(
                "Reopen checkout?",
                isPresented: $showReopenConfirm,
                titleVisibility: .visible
            ) {
                Button("Reopen checkout", role: .destructive) { Task { await reopenCheckout() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This undoes the recorded payment so you can collect it again.")
            }

            if let reopenError {
                Text(reopenError).font(BrandFont.body(11)).foregroundStyle(BrandColor.ember)
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
                Button {
                    importPhase = phase
                    showLibraryPicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Upload from library").font(BrandFont.body(14, .semibold))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(BrandColor.accent.opacity(0.12))
                    .foregroundStyle(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(importing)
                if importing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(BrandColor.accent)
                        Text("Adding photos…").font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }
                if let importMessage {
                    Text(importMessage).font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
                uploadStatusRow()
                sharingConsentRow()
            }
        }
    }

    /// What the durable uploader still owes the server, and the one control that
    /// can act on it.
    ///
    /// This is shown so the pro can SEE that leaving is safe — the photos keep
    /// uploading in the background, including after the session is closed out and
    /// after the app is killed. It is deliberately not a blocker: nothing on this
    /// screen waits for it.
    @ViewBuilder
    private func uploadStatusRow() -> some View {
        if uploads.blockedCount > 0 {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(uploads.blockedCount) photo\(uploads.blockedCount == 1 ? "" : "s") couldn’t be saved")
                    .font(BrandFont.body(12))
                Spacer()
                Button("Try again") { Task { await uploads.retryNow() } }
                    .font(BrandFont.body(12, .semibold))
            }
            .foregroundStyle(BrandColor.amber)
        } else if uploads.pendingCount > 0 {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(BrandColor.accent)
                Text("\(uploads.pendingCount) photo\(uploads.pendingCount == 1 ? "" : "s") uploading — safe to carry on")
                    .font(BrandFont.body(12))
            }
            .foregroundStyle(BrandColor.textMuted)
        }
    }

    /// Pull photos the pro already has into this booking's before/after set.
    ///
    /// Reuses `CameraLibraryImport.prepare` — the same transcode, orientation
    /// bake and focal read the camera's own import door uses — so a photo added
    /// here and a photo added there are indistinguishable downstream. The bytes
    /// go to the byte vault and the durable queue, never straight to the network.
    ///
    /// `capturedAt` is nil on purpose: a library photo has no capture moment this
    /// can honestly claim (see `CameraLibraryImport`).
    private func importFromLibrary(_ items: [PhotosPickerItem], phase: MediaPhase) async {
        guard !importing else { return }
        importing = true
        importMessage = nil
        defer {
            importing = false
            importPhase = nil
        }

        var added = 0
        var unreadable = 0
        for item in items {
            guard let raw = try? await item.loadTransferable(type: Data.self),
                  let prepared = await CameraLibraryImport.prepare(raw) else {
                unreadable += 1
                continue
            }
            guard SessionByteVault.writePendingUpload(
                prepared.jpeg, bookingId: bookingId, phase: phase,
                focal: prepared.focal, capturedAt: nil
            ) != nil else {
                unreadable += 1
                continue
            }
            added += 1
        }

        if added > 0 { uploads.enqueue() }
        if unreadable > 0 {
            importMessage = added > 0
                ? "Added \(added). \(unreadable) couldn’t be read."
                : "Couldn’t read those photos — try different ones."
        } else {
            importMessage = nil
        }
    }

    /// Passive media-use consent indicator (C4): tells the pro up-front whether
    /// the client approved featuring this session's photos publicly, so a publish
    /// attempt doesn't get its first "no" from the server-side share guard.
    @ViewBuilder
    private func sharingConsentRow() -> some View {
        HStack(spacing: 6) {
            Image(systemName: clientUseConsent ? "checkmark.seal.fill" : "lock.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(clientUseConsent
                 ? "Client approved sharing these publicly"
                 : "Private until the client approves sharing")
                .font(BrandFont.body(12))
        }
        .foregroundStyle(clientUseConsent ? BrandColor.emerald : BrandColor.textMuted)
    }

    @ViewBuilder
    private func thumbnail(_ item: ProBookingMediaItem) -> some View {
        // A video row without a real image thumb must NOT fall back to the
        // signed .mov URL — AsyncImage can't decode video, so the tile would
        // spin forever. Show a static video badge instead.
        let thumbString = item.mediaType == .video
            ? (item.renderThumbUrl ?? item.thumbUrl)
            : item.displayThumbUrl
        Button {
            // The pro looking at their own session's shots — save + export on.
            viewingMedia = FullscreenMedia.proSession(item, before: pairedBefore(for: item))
        } label: {
            ZStack {
                BrandColor.bgSecondary
                if let urlString = thumbString, let url = URL(string: urlString) {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
                        ProgressView().tint(BrandColor.accent)
                    }
                } else {
                    Image(systemName: item.mediaType == .video ? "video" : "photo")
                        .foregroundStyle(BrandColor.textMuted)
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

    private func startedTimeLabel(_ iso: String?) -> String {
        guard let iso else { return "—" }
        return Wire.dateTime(iso, timeZone: detail?.timeZone)
    }

    private func closeoutInput(_ state: ProSessionState) -> ProSessionCloseoutInput {
        ProSessionCloseoutInput(
            afterCount: afterCount,
            hasAftercareDraft: state.aftercare?.hasDraft ?? false,
            hasFinalizedAftercare: state.aftercare?.isSent ?? false,
            hasPaymentCollected: state.checkout?.paymentCollectedAt != nil,
            hasCheckoutClosed: state.checkout?.isClosed ?? false,
            hasConsultationApproved: state.isConsultationApproved,
        )
    }

    // MARK: - Actions

    /// Load the session state, detail, media and payment methods.
    ///
    /// `silent` is for a refresh the pro did not ask for (a live-sync tick after
    /// the client acted): keep the last good screen when the refresh fails
    /// instead of replacing what they are working on with an error card. The
    /// first, explicit load still surfaces failures — same rule `loadMedia`
    /// already follows.
    private func load(silent: Bool = false) async {
        do {
            async let stateTask = session.client.proSession.state(bookingId: bookingId)
            async let detailTask = try? session.client.proBookings.detail(bookingId: bookingId)
            let result = try await stateTask
            detail = await detailTask
            // K17-A: a SIBLING of `state`, so it is adopted here rather than read
            // off the phase. A reload after a signature lands drops the row; a
            // reload while it is still outstanding keeps warning.
            unsignedConsentForms = result.unsignedConsentForms
            phase = .loaded(result.state)
        } catch let error as APIError {
            if !silent { phase = .failed(error.userMessage) }
        } catch {
            if !silent { phase = .failed("Couldn’t load this session.") }
        }
        await loadMedia()
        await loadPaymentMethods()
    }

    private func loadMedia() async {
        // Keep prior media/consent on a failed refresh (don't blank the UI).
        if let response = try? await session.client.proMedia.listWithConsent(bookingId: bookingId) {
            media = response.items
            clientUseConsent = response.clientUseConsent
        }
    }

    private func reloadAfterCapture() async {
        await loadMedia()
        await load()
    }

    /// Feature the visible pair's "after" into the portfolio (server publishes the
    /// before/after `LookPost`), pinning the exact "before" the pro is viewing so a
    /// multi-pair session doesn't fall back to the auto-paired earliest before. `run`
    /// reloads media, so the button flips to its "Published" state on success; a
    /// consent 403 surfaces via `actionError`.
    private func publishTransformation(_ pair: ComparePair) async {
        await run {
            try await session.client.proProfile.setMediaFeaturedInPortfolio(
                mediaId: pair.afterItem.id,
                beforeAssetId: pair.beforeItem.id,
                featured: true
            )
        }
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

    private func reopenCheckout() async {
        guard !working else { return }
        reopenError = nil
        working = true
        defer { working = false }
        do {
            try await session.client.proBookings.reopenCheckout(bookingId: bookingId)
            session.signalRefresh()
            await load()
        } catch let error as APIError {
            reopenError = error.userMessage
        } catch {
            reopenError = "Could not reopen checkout. Check your connection and try again."
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
