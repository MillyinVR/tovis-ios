import PhotosUI
import SwiftUI
import TovisKit
import UIKit

struct ConsultFlowView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// What this consult hangs off. Book the Look (B8) added the look case: the
    /// SAME flow, reached from a look instead of from a booking.
    let anchor: ConsultAnchor
    let professionalId: String
    var suppliedService: (any ConsultServicing)?
    /// The look's primary media, on the look-anchored path — carried through so
    /// the booking sheet's cover is the photo she tapped, not an empty well.
    let lookMediaId: String?

    /// Convenience for the booking-anchored callers, which is every shipped
    /// entry point — they pass a booking id and nothing else changes.
    init(bookingId: String, professionalId: String,
         suppliedService: (any ConsultServicing)? = nil) {
        self.anchor = .booking(bookingId)
        self.professionalId = professionalId
        self.suppliedService = suppliedService
        self.lookMediaId = nil
    }

    init(anchor: ConsultAnchor, professionalId: String,
         lookMediaId: String? = nil,
         suppliedService: (any ConsultServicing)? = nil) {
        self.anchor = anchor
        self.professionalId = professionalId
        self.suppliedService = suppliedService
        self.lookMediaId = lookMediaId
    }

    @State private var model: ConsultFlowViewModel?
    @State private var showRevokeConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var fullscreen: FullscreenMedia?
    /// The sticky CTA's destination, once she taps it.
    @State private var bookLaunch: ConsultThreadBookCta?
    /// Resolved from the look's own service when the sheet opens.
    @State private var bookOffering: ProOffering?
    @State private var bookUnavailable = false

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView().tint(BrandColor.accent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Beauty consult")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(BrandColor.textSecondary)
                }
            }
            .task {
                guard model == nil else {
                    // Coming BACK to this screen. The durable queue may have
                    // finished legs while it was gone — in another process,
                    // even — so the served slot state is re-read rather than
                    // trusted from whenever this view last saw it.
                    await model?.refreshThread()
                    return
                }
                let created = ConsultFlowViewModel(
                    anchor: anchor,
                    professionalId: professionalId,
                    service: suppliedService ?? session.client.consult
                )
                model = created
                await created.start()
            }
            // A screen nobody is looking at must not keep polling. `.task`
            // above is not enough on its own: it is cancelled on disappear, but
            // the poll lives on the view model, which outlives it.
            .onDisappear { model?.stopPolling() }
            .confirmationDialog(
                "Stop this consult and withdraw your permission?",
                isPresented: $showRevokeConfirmation,
                titleVisibility: .visible
            ) {
                Button("Withdraw permission", role: .destructive) {
                    Task { await model?.revokeSensitiveConsent() }
                }
                Button("Keep consult", role: .cancel) {}
            } message: {
                Text("You won’t be able to add answers or photos, or create a plan, until you agree again. Temporary consult photos will be removed. Photos already saved in your appointment record will stay there.")
            }
            .confirmationDialog("Delete this consultation?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete consultation", role: .destructive) { Task { await model?.deleteConsult() } }
                Button("Keep consultation", role: .cancel) {}
            } message: {
                Text("Your answers and temporary consult photos will be deleted. You can start this look again. Photos already saved in your appointment record will stay there.")
            }
            .onChange(of: model?.deleted) { _, deleted in if deleted == true { dismiss() } }
            .mediaFullscreenCover($fullscreen)
            // 🔴 Book the look runs the ORDINARY look-booking path, NOT the
            // consult proposal. The proposal refuses with ESTIMATE_MISSING until
            // the analysis commits an estimate, and the analysis takes about 100
            // seconds — longer than the spark lasts. The consult attaches to the
            // resulting booking and carries on as prep.
            .sheet(item: $bookLaunch) { book in
                if let consultId = book.proposalConsultId {
                    ConsultBookingView(consultId: consultId, lookMediaId: book.lookMediaId ?? lookMediaId)
                } else if let offering = bookOffering {
                    BookingFlowView(
                        professionalId: professionalId,
                        proName: model?.professionalDisplayName ?? "",
                        offering: offering,
                        lookMediaId: book.lookMediaId ?? lookMediaId,
                        // P7a-2 — the look and the consult travel with the tap.
                        // `lookPostId` is what makes the server stamp
                        // `Booking.sourceLookPostId`; `sparkConsultId` is what
                        // makes it stamp the consult link. Before this, an iOS
                        // spark booking carried neither and the thread could
                        // never find the appointment it had just made.
                        lookPostId: book.lookPostId,
                        sparkConsultId: model?.thread?.consultId
                    )
                } else {
                    // Resolving the offering is a network read, so the sheet
                    // opens on it rather than making the tap feel dead. A look
                    // whose service the pro no longer offers says so instead of
                    // silently reserving a different appointment.
                    VStack(spacing: 14) {
                        if bookUnavailable {
                            Text("We couldn’t open times for this look. Message your professional and she can set it up.")
                                .font(BrandFont.body(14))
                                .foregroundStyle(BrandColor.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(24)
                        } else {
                            ProgressView().tint(BrandColor.accent)
                        }
                    }
                    .task {
                        bookUnavailable = false
                        bookOffering = await LookBooking.offering(
                            client: session.client,
                            professionalId: professionalId,
                            serviceId: book.serviceId
                        )
                        bookUnavailable = bookOffering == nil
                    }
                }
            }
            .onChange(of: bookLaunch?.id) { _, _ in bookOffering = nil }
        }
        .tint(BrandColor.accent)
    }

    /// P5a — the whole flow, as a thread.
    ///
    /// The six-arm `switch model.stage` this replaced showed exactly ONE step at
    /// a time and threw the rest away. The thread shows the history, the one
    /// step that is open, and a sticky Book the look button — all from the one
    /// served message list.
    @ViewBuilder
    private func content(_ model: ConsultFlowViewModel) -> some View {
        ConsultThreadView(
            model: model,
            lookMediaId: lookMediaId,
            onFullscreen: { media in fullscreen = media },
            onBook: { book in bookLaunch = book }
        )
        .safeAreaInset(edge: .top) {
            ConsultManagementControls(model: model, onDelete: { showDeleteConfirmation = true })
        }
        .safeAreaInset(edge: .bottom) {
            if model.canRevokeConsent {
                Button("Privacy & stop this consult") { showRevokeConfirmation = true }
                    .disabled(model.busy)
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.textMuted)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(BrandColor.bgPrimary)
            }
        }
    }
}

func consultQualityReasonMessage(_ code: String?) -> String {
    switch code {
    case "WARM_INDOOR_LIGHT":
        return "Warm indoor lighting — true colors can’t be read accurately under it."
    case "COLOR_CAST":
        return "A color tint in the light is masking the true colors."
    case "VIEW_MISMATCH":
        return "This doesn’t look like the view this photo asks for."
    case "HAIR_NOT_VISIBLE":
        return "The hair isn’t clearly visible in this photo."
    case "SUBJECT_NOT_VISIBLE":
        return "The area this photo asks for isn’t clearly visible."
    case "BLURRY":
        return "The photo is too blurry to use."
    case "TOO_DARK":
        return "The photo is too dark to read."
    case "TOO_BRIGHT":
        return "The photo is too bright or washed out."
    default:
        return "This photo can’t be used for the analysis."
    }
}

struct ConsultPhotoPickerSlot: View {
    let shot: ConsultCaptureShot
    let slot: ConsultCaptureSlot?
    /// The consult this slot belongs to — only used to key the daylight
    /// reminder, so two consults cannot share one pending notification.
    let consultId: String
    let thumbnail: UIImage?
    /// Where the durable queue has got to with this slot, if it owes anything.
    let queueStage: ConsultCaptureStage?
    /// The server's refusal for this slot, when retrying cannot fix it.
    let queueBlockedReason: String?
    /// Whether the queue's last attempt actually failed and it is backing off —
    /// the difference between "sending" and "waiting on a connection".
    let queueStalled: Bool
    let disabled: Bool
    /// The RAW still, from the guided camera or the picker. Quality checking,
    /// the P3 crop and the encode all happen behind this, in the flow model.
    let onStill: (Data) async -> Void
    let onThumbnailTap: (UIImage) -> Void
    /// The on-device refusal for this slot, if the last still did not pass.
    ///
    /// 🔴 Owned by the MODEL, not by this view (P3). The camera used to hold
    /// this and show it in place, which is exactly the in-camera quality gate
    /// P3 removed — the client is back on this list before there is a verdict,
    /// so the verdict has to live somewhere that is still on screen.
    let localRetakeReason: String?
    /// Would the SERVER accept this shot right now? (P3b.)
    ///
    /// 🔴 Never derived from the message's `state`. A BLOCKED request is
    /// deliberately tappable — see `ConsultThreadMessage.shootable`.
    let shootable: Bool

    @State private var pick: PhotosPickerItem?
    @State private var preparationError: ConsultClientFailure?
    @State private var showGuidedCamera = false
    @State private var daylightReminder: ConsultDaylightReminder.Availability = .unavailable
    @State private var daylightReminderFailed = false

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(shot.title)
                                .font(BrandFont.body(16, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                            Spacer()
                            statusBadge
                        }
                        Text(shot.instruction)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                        if let statusDetail {
                            Text(statusDetail)
                                .font(BrandFont.body(12))
                                .foregroundStyle(
                                    status == .couldNotSend
                                        ? BrandColor.ember : BrandColor.textMuted
                                )
                        }
                    }
                    if let thumbnail {
                        Button { onThumbnailTap(thumbnail) } label: {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("View your \(shot.title) photo")
                        .accessibilityHint("Opens the full photo you took")
                    }
                }

                if slot?.state == .rejected {
                    // 🔴 A second refusal must not be byte-identical to the
                    // first — that is what made a working retake read as a
                    // stuck upload (2026-09-07). The count, the "too", and a
                    // DIFFERENT lever are the three things that differ.
                    let guidance = consultSlotRetakeGuidance(
                        reasonCode: slot?.qualityReasonCode,
                        previousReasonCode: slot?.previousReasonCode,
                        retakeTip: slot?.retakeTip,
                        attemptCount: slot?.attemptCount ?? 0
                    )
                    let reason = guidance.repeatedLine
                        ?? consultQualityReasonMessage(slot?.qualityReasonCode)
                    let step = guidance.nextStep
                    VStack(alignment: .leading, spacing: 3) {
                        if let attempt = guidance.attemptLabel {
                            Text(attempt)
                                .font(BrandFont.mono(10))
                                .foregroundStyle(BrandColor.textMuted)
                        }
                        Text(step.map { "\(reason) \($0)" } ?? reason)
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.amber)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(guidance.attemptLabel.map { "\($0). " } ?? "")Why this photo was refused: \(reason)\(step.map { " Try this: \($0)" } ?? "")"
                    )
                }
                // The coach's aside on a warm ACCEPTANCE. Never between her and
                // the next shot: the photo passed, this only says what the light
                // costs the reading, and offers the one thing that would fix it.
                if slot?.state == .accepted, slot?.qualityWarningCode != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        // 🔴 A QUESTION only when it can be answered in one tap.
                        // With notifications off there is no reminder to offer,
                        // and "want to retake this tomorrow?" with no control
                        // under it is a question left hanging — so it becomes a
                        // statement she can act on whenever she likes.
                        Text(
                            daylightReminder == .unavailable
                                ? "Daylight reads truer — worth retaking this one tomorrow if you get the chance."
                                : "Daylight reads truer. Want to retake this one tomorrow?"
                        )
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textSecondary)
                        switch daylightReminder {
                        case .offerable:
                            Button {
                                Task {
                                    let ok = await ConsultDaylightReminder.schedule(
                                        consultId: consultId,
                                        shotKey: shot.key,
                                        shotTitle: shot.title
                                    )
                                    daylightReminderFailed = !ok
                                    if ok { daylightReminder = .alreadySet }
                                }
                            } label: {
                                Label("Remind me tomorrow", systemImage: "bell")
                                    .font(BrandFont.body(12, .semibold))
                                    .foregroundStyle(BrandColor.accent)
                            }
                            .buttonStyle(.plain)
                        case .alreadySet:
                            Label("Reminder set for tomorrow", systemImage: "bell.fill")
                                .font(BrandFont.body(12))
                                .foregroundStyle(BrandColor.textMuted)
                        case .unavailable:
                            // Notifications are off. No offer rather than a
                            // button that cannot do what it says.
                            EmptyView()
                        }
                        if daylightReminderFailed {
                            Text("We couldn’t set that reminder.")
                                .font(BrandFont.body(12))
                                .foregroundStyle(BrandColor.ember)
                        }
                    }
                    .task(id: slot?.captureId) {
                        daylightReminder = await ConsultDaylightReminder.availability(
                            consultId: consultId, shotKey: shot.key
                        )
                    }
                }

                if let preparationError {
                    Text(preparationError.message)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.ember)
                }
                if let localRetakeReason {
                    Text(localRetakeReason)
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.amber)
                        .accessibilityLabel("This photo needs another try: \(localRetakeReason)")
                }

                if shootable {
                    Button { showGuidedCamera = true } label: {
                        Label(guidedButtonTitle, systemImage: "camera.viewfinder")
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.onAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(BrandColor.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .disabled(disabled)

                    PhotosPicker(selection: $pick, matching: .images) {
                        Label(pickerButtonTitle, systemImage: "photo.on.rectangle")
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(disabled ? BrandColor.textMuted : BrandColor.textSecondary)
                    }
                    .disabled(disabled)
                } else {
                    // 🔴 No camera and no picker — not a disabled one. A control
                    // that is present but refuses is what taught the client to
                    // press it twice; both of her `eyes_closeup` attempts on
                    // 2026-09-06 came back "This consult changed".
                    Text("This one opens after you book.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
        .fullScreenCover(isPresented: $showGuidedCamera) {
            ConsultGuidedCaptureView(shot: shot, onStill: onStill)
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                defer { pick = nil }
                do {
                    guard let source = try await item.loadTransferable(type: Data.self) else {
                        preparationError = .invalidPhoto
                        return
                    }
                    preparationError = nil
                    // One road for both doors: a picked photo goes through the
                    // same model path as a shuttered one, so it gets the same
                    // quality check, the same crop, and the same place to say so.
                    await onStill(source)
                } catch {
                    preparationError = .invalidPhoto
                }
            }
        }
    }

    private var guidedButtonTitle: String {
        switch slot?.state {
        case .accepted: return "Retake with guided camera"
        case .rejected: return "Take guided retake"
        default: return "Open guided camera"
        }
    }

    private var pickerButtonTitle: String {
        switch slot?.state {
        case .accepted: return "Replace from Photos instead"
        case .rejected: return "Choose a retake from Photos instead"
        default: return "Choose from Photos instead"
        }
    }

    /// What this slot HONESTLY is.
    ///
    /// 🔴 The old version had three outcomes — Passed, Retake, and "Required"
    /// for everything else — so a photograph that had been taken and was still
    /// working its way to the server read as one that had never been taken.
    /// That is what made the prod failure invisible to the client: she was told
    /// to do again the thing she had already done.
    ///
    /// The queue's own stage OUTRANKS the served slot state whenever it has
    /// one, because the queue knows about a shot the server has not been told
    /// about yet. "Required" is now reachable only when the queue owes nothing
    /// for this slot AND the server has nothing for it either.
    private enum SlotStatus {
        case uploading
        case waiting
        case checking
        case passed
        case retake
        case couldNotSend
        case required
    }

    private var status: SlotStatus {
        if queueBlockedReason != nil { return .couldNotSend }
        switch queueStage {
        case .queued, .ticketed, .transferring:
            return queueStalled ? .waiting : .uploading
        case .uploaded, .attached:
            return .checking
        case .blocked:
            return .couldNotSend
        case .checked, .released, .backoff, .viewDismissed, .none:
            break
        }
        switch slot?.state {
        case .accepted: return .passed
        case .rejected: return .retake
        // UPLOADED means the server holds bytes with no verdict yet — a shot in
        // the middle of the chain, never an empty slot.
        case .uploaded: return .checking
        default: return .required
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .uploading:
            inlineStatus("Uploading", icon: "arrow.up.circle.fill",
                         tone: BrandColor.accent, spinning: true)
        case .waiting:
            inlineStatus("Uploading", icon: "wifi.exclamationmark",
                         tone: BrandColor.amber, spinning: false)
        case .checking:
            inlineStatus("Checking", icon: "hourglass",
                         tone: BrandColor.accent, spinning: true)
        case .passed:
            inlineStatus("Passed", icon: "checkmark.circle.fill",
                         tone: BrandColor.emerald, spinning: false)
        case .retake:
            inlineStatus("Retake", icon: "arrow.clockwise.circle.fill",
                         tone: BrandColor.amber, spinning: false)
        case .couldNotSend:
            inlineStatus("Couldn’t send", icon: "exclamationmark.triangle.fill",
                         tone: BrandColor.ember, spinning: false)
        case .required:
            Text("Required")
                .font(BrandFont.body(11, .semibold))
                .foregroundStyle(BrandColor.textMuted)
        }
    }

    private func inlineStatus(
        _ title: String, icon: String, tone: Color, spinning: Bool
    ) -> some View {
        HStack(spacing: 5) {
            if spinning {
                ProgressView().controlSize(.mini).tint(tone)
            } else {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            }
            Text(title)
        }
        .font(BrandFont.body(12, .semibold))
        .foregroundStyle(tone)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shot.title): \(title)")
    }

    /// The sentence under the title when the badge alone would leave her
    /// guessing. Silence is the right answer for the ordinary states.
    private var statusDetail: String? {
        switch status {
        case .waiting:
            return "Waiting for a connection — this keeps trying on its own, even if you close this screen."
        case .uploading:
            return "Sending — you can keep going; this finishes on its own."
        case .checking:
            return "Checking this photo."
        case .couldNotSend:
            return queueBlockedReason
        case .passed, .retake, .required:
            return nil
        }
    }
}

// 🔴 P5d DELETED `consultInspirationFocusHints` (and its web twin,
// `INSPIRATION_FOCUS`).
//
// It was a sentence telling the client where to LOOK — "zoom into the hair and
// look at the mix of colors" — written once per question key and guessed at per
// pack. A card does not need one: it shows her the crop.
//
// Do not reintroduce it. A hint that describes a region the server can send is
// a second, hand-maintained answer to a question the reading already answers,
// and it drifts silently the moment a pack asks something it was never taught.

/// The inspiration source decision: add one reference photo of a look, or
/// continue without one. Uses the photo library only — an inspiration picture
/// is of a LOOK someone else wears, not something the guided camera frames.
struct ConsultInspirationPhotoPicker: View {
    let busy: Bool
    let onJPEG: (Data) async -> Void
    let onSkip: () -> Void

    @State private var pick: PhotosPickerItem?
    @State private var preparing = false
    @State private var preparationError: ConsultClientFailure?

    private struct PendingFocus: Identifiable {
        let id = UUID()
        let source: Data
        let image: UIImage
    }
    @State private var pendingFocus: PendingFocus?

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 10) {
                if let preparationError {
                    Text(preparationError.message)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.ember)
                }
                PhotosPicker(selection: $pick, matching: .images) {
                    Group {
                        if busy || preparing {
                            ProgressView().tint(BrandColor.onAccent)
                        } else {
                            Label("Add an inspiration photo", systemImage: "photo.on.rectangle")
                                .font(BrandFont.body(14, .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(BrandColor.onAccent)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(busy || preparing)
                Button(action: onSkip) {
                    Text("Continue without one")
                        .font(BrandFont.body(14, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(BrandColor.textPrimary)
                        .background(BrandColor.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(busy || preparing)
            }
        }
        .accessibilityIdentifier("consult-inspiration-source-decision")
        .sheet(item: $pendingFocus) { pending in
            ConsultInspirationFocusView(image: pending.image, busy: busy || preparing,
                onConfirm: { rect in
                    guard !preparing, !busy else { return }
                    preparing = true
                    Task {
                        defer { preparing = false }
                        guard let jpeg = await ConsultPhotoPreparation.confirmedInspirationJPEG(from: pending.source, rect: rect) else {
                            preparationError = .invalidPhoto
                            pendingFocus = nil
                            return
                        }
                        pendingFocus = nil
                        await onJPEG(jpeg)
                    }
                }, onCancel: { pendingFocus = nil })
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                defer { pick = nil }
                preparing = true
                defer { preparing = false }
                do {
                    guard let source = try await item.loadTransferable(type: Data.self),
                          let preview = await ConsultPhotoPreparation.jpeg(from: source),
                          let decoded = UIImage(data: preview) else {
                        preparationError = .invalidPhoto
                        return
                    }
                    preparationError = nil
                    pendingFocus = PendingFocus(source: source, image: decoded)
                } catch {
                    preparationError = .invalidPhoto
                }
            }
        }
    }
}

/// Keeps the uploaded inspiration photo on screen through the question flow,
/// with the per-question focus hint. Tapping opens the zoomable fullscreen
/// viewer — the parity of web's pinch/scroll/double-tap zoom.
struct ConsultInspirationImagePanel: View {
    let model: ConsultFlowViewModel
    let questionKey: String
    let referenceNote: String
    let onTap: (URL) -> Void

    @State private var url: URL?
    @State private var failed = false
    /// Bumped by Retry so the `.task` re-runs. A FAILURE never bumps it — the
    /// panel waits for the client, it does not re-request on its own.
    @State private var attempt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let url {
                Button { onTap(url) } label: {
                    DownsampledRemoteImage(url: url) {
                        HStack(spacing: 10) {
                            ProgressView().tint(BrandColor.accent)
                            Text("Loading your inspiration photo…")
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Your inspiration photo — tap to zoom")
            } else if failed {
                // Surfaced, not silent: the client is being asked what she
                // liked about a photo, so she has to be told when we cannot
                // put it in front of her — and given a way to try again.
                BrandSurface {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("We couldn’t load your inspiration photo.")
                            .font(BrandFont.body(14, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text("Answer these questions with the photo in front of you — tap retry, and if it still won’t load, go back a step and pick it again.")
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textSecondary)
                        Button("Retry") { attempt += 1 }
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.accent)
                            .accessibilityIdentifier("consult-inspiration-image-retry")
                    }
                }
                .accessibilityIdentifier("consult-inspiration-image-error")
            } else {
                BrandSurface {
                    Text("Loading your inspiration photo…")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                }
            }
            Text(referenceNote)
                .font(BrandFont.body(11))
                .foregroundStyle(BrandColor.textMuted)
        }
        .accessibilityIdentifier("consult-inspiration-image")
        .task(id: "\(questionKey)#\(attempt)") {
            // Refetch per question (and on Retry) so the short-lived read URL
            // is renewed before it can expire mid-questionnaire — the model
            // caches it and only hits the network when it is close to stale.
            switch await model.inspirationImage() {
            case let .ready(fetched):
                url = fetched
                failed = false
            case .failed:
                url = nil
                failed = true
            case .unavailable:
                // The panel only renders when `imageAvailable` is true, so
                // this is a source that went away mid-flow: no image, and
                // nothing broken to report.
                url = nil
                failed = false
            }
        }
    }
}

/// One server-served inspiration question: option chips, and for the final
/// free-text question the first text-entry surface in the consult flow —
/// a bounded note with a GOOD/BAD/BOTH sentiment, where leaving everything
/// blank means "nothing else".
/// The inspiration question, as taps only.
///
/// 🔴 The free-text note and its GOOD/BAD/BOTH sentiment picker are GONE from
/// the thread (P5a: "no free-text input"). Nothing is lost from the contract:
/// every question that allowed a note also carries a tappable option, and the
/// server treats a blank note as that option. What the removal buys is the
/// property that makes a scripted thread worth having — every prompt is
/// deterministic, instant, and free per message.
struct ConsultInspirationQuestionView: View {
    let question: ConsultInspirationQuestion
    let busy: Bool
    /// 🔴 False on a CARD, which renders the question itself — after its crop
    /// and its plain-language name, which is the whole point of the card's
    /// ordering. Left true it renders a SECOND copy of the same sentence, above
    /// the name, putting the jargon-free word after a question the client has
    /// already been asked. The web twin shipped exactly that until a browser
    /// caught it; both copies are correct on their own, so no unit test can.
    var showLabel: Bool = true
    var initialSelection: [String] = []
    var initialText: String = ""
    var allowClientWords: Bool = true
    let onAnswer: ([String], String) -> Void

    @State private var selected: [String] = []
    @State private var text: String = ""

    private var needsSelection: Bool {
        text.utf16.count > 600 || (question.kind != .text && selected.count < question.minSelections &&
            !(allowClientWords && question.allowText && question.key != "understanding_check" && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    // No BrandSurface of its own: in the thread this always renders INSIDE a
    // message card, and a surface nested in a surface is an invisible box.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showLabel {
                Text(question.label)
                    .font(BrandFont.body(16, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
            }
            if let helpText = question.helpText {
                Text(helpText)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            }
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(question.options) { option in
                    optionChip(option)
                }
            }
            if allowClientWords && question.allowText {
                ConsultClientWordsInput(text: $text, busy: busy)
            }
            Button {
                onAnswer(selected, text)
            } label: {
                Text(ConsultThreadCopy.questionNext)
                    .font(BrandFont.body(14, .semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 11)
                    .foregroundStyle(BrandColor.onAccent)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(busy || needsSelection)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("consult-inspiration-question-\(question.key)")
        .onAppear { selected = initialSelection; text = initialText }
    }

    private func optionChip(_ option: ConsultInspirationQuestionOption) -> some View {
        let active = selected.contains(option.value)
        return Button {
            selected = ConsultInspirationAnswering.toggle(
                option.value, in: selected, question: question
            )
        } label: {
            Text(option.label)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(active ? BrandColor.accent : BrandColor.bgSurface)
                .clipShape(Capsule())
                // The outline is what makes an unselected chip read as a
                // button inside a card whose fill is the same colour.
                .overlay(
                    active
                        ? nil
                        : Capsule().stroke(
                            BrandColor.textMuted.opacity(0.28), lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}


struct ConsultManagementControls: View {
    let model: ConsultFlowViewModel
    let onDelete: () -> Void
    var body: some View {
            if model.canEditAnswers || model.thread?.controls?.canDelete == true {
                HStack(spacing: 16) {
                    if model.canEditAnswers {
                        Button(model.isEditingAnswers ? "Done editing" : "Edit answers") { model.editingAnswers.toggle() }
                    }
                    Spacer(minLength: 0)
                    if model.thread?.controls?.canDelete == true {
                        Button("Delete consultation", role: .destructive) { onDelete() }
                    }
                }
                .font(BrandFont.body(13, .semibold))
                .padding()
                .background(BrandColor.bgPrimary)
                .disabled(model.busy)
            }
    }
}

struct ConsultClientWordsInput: View {
    @Binding var text: String
    let busy: Bool

    var body: some View {
        Text(ConsultThreadCopy.ownWordsLabel)
            .font(BrandFont.body(13, .semibold))
            .foregroundStyle(BrandColor.textSecondary)
        TextField(ConsultThreadCopy.ownWordsPlaceholder, text: $text, axis: .vertical)
            .lineLimit(2...5)
            .textFieldStyle(.roundedBorder)
            .disabled(busy)
            .accessibilityIdentifier("consult-inspiration-own-words")
        if text.utf16.count > 600 {
            Text(ConsultThreadCopy.ownWordsLimit).font(BrandFont.body(12))
        }
    }
}
