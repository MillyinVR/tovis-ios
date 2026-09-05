import SwiftUI
import TovisKit
import UIKit

// P5a — the consult as a THREAD, on the device.
//
// The screen is a message list plus a sticky Book the look button. The shell
// (`ConsultThreadScroll`, `ConsultThreadBubble`, `ConsultThreadCardView`) knows
// nothing about consults — the handoff says the pro-side mentor "reuses the same
// thread component with a different script", so everything that knows what a
// consult STEP is lives in `ConsultThreadMessageView` and below.
//
// 🔴 The photo request reuses `ConsultPhotoPickerSlot` verbatim. Its
// Uploading → Checking → Passed / Retake ladder already resolves the durable
// queue's stage over the served slot state (P2d), and rewriting it here would be
// a second answer to "has this photo actually arrived" — the exact question the
// original prod failure got wrong.

// MARK: - The shell (script-agnostic)

/// A spoken bubble.
///
/// The app's side is a plain surface rather than the accent fill the client's
/// side gets: the accent is what "you said this" looks like in messaging, and
/// borrowing it for the app would make the app read as the person you are
/// talking to. The app is never the professional.
struct ConsultThreadBubble<Content: View>: View {
    let author: ConsultThreadAuthor
    @ViewBuilder var content: Content

    private var mine: Bool { author == .client }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            content
                .font(BrandFont.body(15))
                .foregroundStyle(mine ? BrandColor.onAccent : BrandColor.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(mine ? BrandColor.accent : BrandColor.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    mine
                        ? nil
                        : RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(BrandColor.textMuted.opacity(0.12), lineWidth: 1)
                )
                .frame(maxWidth: 300, alignment: mine ? .trailing : .leading)
            if !mine { Spacer(minLength: 40) }
        }
    }
}

/// A card message — anything with controls in it.
///
/// `dimmed` is settled history: still readable, visibly done, never removed. A
/// thread you cannot scroll back through is a wizard.
struct ConsultThreadCardView<Content: View>: View {
    var dimmed: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        BrandSurface { content }
            .opacity(dimmed ? 0.6 : 1)
    }
}

/// The thread itself: the list, and landing on the message that is waiting.
///
/// 🔴 The scroll is keyed on `openMessageId`, NOT on the message list. Re-running
/// it on every poll would yank the screen out from under a client who had
/// scrolled back to re-read something, once every few seconds.
struct ConsultThreadScroll<Content: View>: View {
    let openMessageId: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(20)
            }
            .onAppear { scrollToOpen(proxy) }
            .onChange(of: openMessageId) { _, _ in scrollToOpen(proxy) }
        }
    }

    private func scrollToOpen(_ proxy: ScrollViewProxy) {
        guard let openMessageId else { return }
        // A beat, so the list has laid out before it is asked to find a row.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(openMessageId, anchor: .center)
            }
        }
    }
}

// MARK: - The consult script

struct ConsultThreadView: View {
    let model: ConsultFlowViewModel
    /// The look's primary media, carried through so the booking sheet's cover is
    /// the photo she tapped.
    let lookMediaId: String?
    let onFullscreen: (FullscreenMedia) -> Void
    let onBook: (ConsultThreadBookCta) -> Void

    var body: some View {
        ConsultThreadScroll(openMessageId: model.nextOpenMessageId) {
            if let failure = model.failure {
                BrandErrorBanner(message: failure.message)
            }
            ForEach(model.messages) { message in
                ConsultThreadMessageView(
                    message: message,
                    model: model,
                    onFullscreen: onFullscreen
                )
                .id(message.id)
            }
            ConsultThreadPrepControls(model: model)
        }
        .safeAreaInset(edge: .bottom) {
            ConsultThreadBookBar(model: model, onBook: onBook)
        }
    }
}

/// One message. `@ViewBuilder` over the kind, with an unknown kind rendering
/// NOTHING — an older build must survive a server that learned a new message
/// type, and skipping one message is the mildest possible failure.
private struct ConsultThreadMessageView: View {
    let message: ConsultThreadMessage
    let model: ConsultFlowViewModel
    let onFullscreen: (FullscreenMedia) -> Void

    var body: some View {
        switch message.kind {
        case .text, .booking:
            if let text = message.text {
                ConsultThreadBubble(author: message.author) {
                    Text(text).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .consent:
            ConsentMessageView(message: message, model: model)
        case .question:
            QuestionMessageView(message: message, model: model)
        case .inspiration:
            InspirationMessageView(
                message: message, model: model, onFullscreen: onFullscreen
            )
        case .photoRequest:
            PhotoRequestMessageView(
                message: message, model: model, onFullscreen: onFullscreen
            )
        case .plan:
            PlanMessageView(message: message, model: model)
        case .unknown:
            EmptyView()
        }
    }
}

private struct ConsentMessageView: View {
    let message: ConsultThreadMessage
    let model: ConsultFlowViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text = message.text {
                ConsultThreadBubble(author: .app) {
                    Text(text).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(message.requirements ?? []) { requirement in
                ConsultThreadCardView(dimmed: requirement.isAccepted) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(requirement.requiredVersion.title)
                                .font(BrandFont.body(16, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                            Spacer()
                            if requirement.isAccepted {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(BrandColor.emerald)
                            }
                        }
                        Text(requirement.requiredVersion.body)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                        if !requirement.isAccepted {
                            Button {
                                Task { await model.accept(requirement) }
                            } label: {
                                Text(ConsultThreadCopy.consentAccept(requirement.kind))
                                    .font(BrandFont.body(14, .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .foregroundStyle(BrandColor.onAccent)
                                    .background(BrandColor.accent)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .disabled(model.busy)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("consult-thread-consent")
    }
}

/// One intake question, one message.
///
/// An ANSWERED question keeps its card — dimmed — and gains the client's own
/// answer as a bubble on her side. That echo is the point: a thread you can
/// scroll back through is the difference between a conversation and a form.
private struct QuestionMessageView: View {
    let message: ConsultThreadMessage
    let model: ConsultFlowViewModel

    var body: some View {
        if let question = message.question {
            let answeredLabel = message.answer.flatMap { value in
                question.options.first { $0.value == value }?.label ?? value
            }
            VStack(alignment: .leading, spacing: 8) {
                ConsultThreadCardView(dimmed: answeredLabel != nil) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(question.label)
                            .font(BrandFont.body(16, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        if let helpText = question.helpText, !helpText.isEmpty {
                            Text(helpText)
                                .font(BrandFont.body(12))
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                        if answeredLabel == nil {
                            FlowLayout(spacing: 8, lineSpacing: 8) {
                                ForEach(question.options) { option in
                                    Button {
                                        Task {
                                            await model.answerIntake(
                                                message, value: option.value
                                            )
                                        }
                                    } label: {
                                        Text(option.label)
                                            .font(BrandFont.body(13, .semibold))
                                            .foregroundStyle(BrandColor.textPrimary)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 9)
                                            // 🔴 The OUTLINE is what makes it
                                            // read as a button. The wizard's
                                            // chips sat on the page ground, so a
                                            // `bgSurface` fill stood out; inside
                                            // a thread CARD that fill is the same
                                            // colour as what it sits on, and the
                                            // options rendered as plain text with
                                            // no affordance at all.
                                            .background(BrandColor.bgSurface)
                                            .clipShape(Capsule())
                                            .overlay(
                                                Capsule().stroke(
                                                    BrandColor.textMuted.opacity(0.28),
                                                    lineWidth: 1
                                                )
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(model.busy)
                                }
                            }
                        }
                    }
                }
                if let answeredLabel {
                    ConsultThreadBubble(author: .client) { Text(answeredLabel) }
                }
            }
            .accessibilityIdentifier("consult-thread-question-\(question.key)")
        }
    }
}

/// The inspiration card.
///
/// P5a renders the CURRENT v1 questions inside a card; P5 replaces the content
/// with the zoom-card script (a crop of the attribute's region + "is this part
/// of what you like?"). The card is what is being fixed in place here, not the
/// wording inside it.
private struct InspirationMessageView: View {
    let message: ConsultThreadMessage
    let model: ConsultFlowViewModel
    let onFullscreen: (FullscreenMedia) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text = message.text {
                ConsultThreadBubble(author: .app) {
                    Text(text).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if message.state != .done {
                ConsultThreadCardView {
                    VStack(alignment: .leading, spacing: 12) {
                        if message.sourceDecisionRequired == true {
                            ConsultInspirationPhotoPicker(
                                busy: model.busy,
                                onJPEG: { data in
                                    await model.uploadInspirationPhoto(message, data)
                                },
                                onSkip: {
                                    Task { await model.skipInspiration(message) }
                                }
                            )
                        }
                        if let question = message.inspirationQuestion {
                            if message.source?.imageAvailable == true {
                                ConsultInspirationImagePanel(
                                    model: model,
                                    questionKey: question.key,
                                    referenceNote: "",
                                    onTap: { url in
                                        onFullscreen(
                                            FullscreenMedia(
                                                id: "consult-inspiration",
                                                source: .remote(url: url, isVideo: false),
                                                overlay: nil
                                            )
                                        )
                                    }
                                )
                            }
                            if let details = message.specificDetailCount,
                               let required = message.requiredSpecificDetailCount,
                               let answered = message.answeredQuestionCount,
                               details < required, answered > 0 {
                                Text("Pick out at least \(required) specific details you love or want to avoid — answers like “not sure” don’t give your professional anything to work from, so a couple of questions come back around.")
                                    .font(BrandFont.body(12))
                                    .foregroundStyle(BrandColor.textPrimary)
                                    .padding(10)
                                    .background(BrandColor.amber.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            ConsultInspirationQuestionView(
                                question: question,
                                busy: model.busy,
                                onAnswer: { values in
                                    Task {
                                        await model.answerInspiration(
                                            message, question: question, selectedValues: values
                                        )
                                    }
                                }
                            )
                            .id(question.key)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("consult-thread-inspiration")
    }
}

/// A photo request — the message that opens the guided (P2d) camera and comes
/// back as a thumbnail carrying its own badge.
private struct PhotoRequestMessageView: View {
    let message: ConsultThreadMessage
    let model: ConsultFlowViewModel
    let onFullscreen: (FullscreenMedia) -> Void

    var body: some View {
        if let shot = message.shot {
            ConsultPhotoPickerSlot(
                shot: shot,
                slot: message.slot,
                thumbnail: model.localThumbnails[shot.key],
                // Where the DURABLE queue has got to with this slot. Nil means it
                // owes nothing and the served slot state is the whole story;
                // anything else OUTRANKS the served state, because the queue
                // knows about a shot the server has not been told about yet.
                queueStage: model.captureStage(for: shot.key),
                queueBlockedReason: model.captureBlockedReason(for: shot.key),
                queueStalled: model.uploads.stalled,
                disabled: model.busy,
                onJPEG: { data in await model.submitPhoto(data, for: message) },
                onThumbnailTap: { image in
                    onFullscreen(
                        .local(id: "consult-shot-\(shot.key.rawValue)", image: image)
                    )
                }
            )
            .opacity(message.slot?.state == .accepted ? 0.75 : 1)
        }
    }
}

/// The plan card — the reveal. P5a renders the existing analysis result.
private struct PlanMessageView: View {
    let message: ConsultThreadMessage
    let model: ConsultFlowViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text = message.text {
                ConsultThreadBubble(author: .app) {
                    Text(text).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ConsultThreadCardView {
                VStack(alignment: .leading, spacing: 12) {
                    if let run = message.run {
                        ConsultAnalysisRunProgressView(
                            run: run,
                            busy: model.busy,
                            onRetry: { Task { await model.startAnalysis() } },
                            onRefresh: { Task { await model.refreshAnalysis() } }
                        )
                    } else if message.awaitingStart == true {
                        Button {
                            Task { await model.startAnalysis() }
                        } label: {
                            Text(model.busy
                                 ? ConsultThreadCopy.planStarting
                                 : ConsultThreadCopy.planStart)
                                .font(BrandFont.body(15, .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .foregroundStyle(BrandColor.onAccent)
                                .background(BrandColor.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(model.busy)
                    }

                    // 🔴 A results payload that failed the C7 provenance check is
                    // REFUSED here, not quietly omitted. The client is told the
                    // plan could not be verified rather than shown a consult
                    // whose plan section simply vanished.
                    if model.resultsContractMismatch {
                        Text("We couldn’t verify this plan belongs to this consult, so we’re not showing it. Your professional still has everything you sent.")
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.ember)
                    } else if let results = message.results {
                        ConsultPlanSummaryView(results: results)
                    }
                }
            }
        }
        .accessibilityIdentifier("consult-thread-plan")
    }
}

/// The plan card's PLACEHOLDER body (P5a): the analysis's own headline
/// directions. The versioned plan card the handoff describes — the reveal, with
/// its own history — is later work.
private struct ConsultPlanSummaryView: View {
    let results: ConsultClientResults

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Optional on the wire (additive), so the same fallback the results
            // screen has always used.
            Text(results.directionsTitle ?? "Directions to discuss")
                .font(BrandFont.body(16, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            ForEach(results.recommendationDirections.prefix(3), id: \.title) { direction in
                Text(direction.title)
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The two capture controls that are NOT steps: the chart-copy preference she
/// can flip at any point in the window, and the offer to run the analysis on the
/// photos that were accepted.
///
/// They sit under the thread rather than inside a message because neither is a
/// question with an answer — turning either into a bubble would put a message in
/// the history she can change after the fact.
private struct ConsultThreadPrepControls: View {
    let model: ConsultFlowViewModel

    var body: some View {
        if let chartCopy = model.chartCopy {
            VStack(alignment: .leading, spacing: 12) {
                if let queueMessage = model.captureQueueMessage {
                    Text(queueMessage)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.amber)
                }
                if model.canRetryPhoto {
                    Button("Try sending your photos again") {
                        Task { await model.retryPhoto() }
                    }
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.accent)
                }
                ConsultThreadCardView {
                    Toggle(isOn: Binding(
                        get: { chartCopy.optIn },
                        set: { newValue in Task { await model.setChartCopy(newValue) } }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ConsultThreadCopy.chartCopyTitle)
                                .font(BrandFont.body(14, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                            Text(ConsultThreadCopy.chartCopyBody)
                                .font(BrandFont.body(12))
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                    }
                    .tint(BrandColor.accent)
                    .disabled(model.busy)
                }
                .accessibilityIdentifier("consult-chart-copy-toggle")

                if model.canOfferPartialContinue {
                    ConsultThreadCardView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(ConsultThreadCopy.partialContinueBody)
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textSecondary)
                            Button {
                                Task { await model.proceedWithAccepted() }
                            } label: {
                                Text(ConsultThreadCopy.partialContinue(
                                    accepted: model.acceptedShotCount,
                                    total: model.totalShotCount
                                ))
                                .font(BrandFont.body(14, .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .foregroundStyle(BrandColor.onAccent)
                                .background(BrandColor.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .disabled(model.busy)
                        }
                    }
                    .accessibilityIdentifier("consult-partial-continue")
                }
            }
        }
    }
}

/// The sticky Book the look bar.
///
/// Disabled until one selfie is in, and it SAYS why — a dead button with no
/// explanation is what makes a client think the app is broken. A consult that
/// cannot be booked at all (booking-anchored, already booked, stopped) gets no
/// bar, because a permanently disabled CTA reads as a bug rather than a rule.
private struct ConsultThreadBookBar: View {
    let model: ConsultFlowViewModel
    let onBook: (ConsultThreadBookCta) -> Void

    var body: some View {
        if let book = model.thread?.book, shouldShow(book) {
            VStack(spacing: 6) {
                Button {
                    onBook(book)
                } label: {
                    Text(ConsultThreadCopy.bookCtaLabel)
                        .font(BrandFont.body(16, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        // 🔴 The INK moves with the fill. `onAccent` is the ink
                        // for the accent fill only; left on the disabled
                        // surface fill it rendered a button with an invisible
                        // label — a blank rounded rectangle above "send one
                        // photo and this opens up". Caught by looking at the
                        // simulator, not by any test: the button was present,
                        // correctly disabled, and had the right accessibility
                        // label the whole time.
                        .foregroundStyle(
                            book.enabled ? BrandColor.onAccent : BrandColor.textMuted
                        )
                        .background(book.enabled ? BrandColor.accent : BrandColor.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            book.enabled
                                ? nil
                                : RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(BrandColor.textMuted.opacity(0.25), lineWidth: 1)
                        )
                }
                .disabled(!book.enabled || model.busy)
                if book.reason == .selfieRequired {
                    Text(ConsultThreadCopy.bookCtaSelfieRequired)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
                if book.reason == .lookNotBookable {
                    Text(ConsultThreadCopy.bookCtaNotBookable)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(BrandColor.bgPrimary)
            .accessibilityIdentifier("consult-thread-book-cta")
        }
    }

    private func shouldShow(_ book: ConsultThreadBookCta) -> Bool {
        switch book.reason {
        case .notLookAnchored, .consultStopped, .alreadyBooked: return false
        default: return true
        }
    }
}

/// P4b's background-run progress, lifted out of the wizard so the plan card can
/// render it.
///
/// Three states, and the difference between them matters more than the styling:
/// a LIVE run shows progress and no buttons (there is nothing useful to press);
/// a RETRYABLE run shows the retry, which is the whole reason a client is not
/// stranded; a settled run offers a refresh.
///
/// The bar is `accessibilityHidden` and the same information is in the headline
/// above it — a progress bar with no accessible name is decoration.
struct ConsultAnalysisRunProgressView: View {
    let run: ConsultAnalysisRun
    let busy: Bool
    let onRetry: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        let progress = ConsultAnalysisRunCopy.progress(for: run)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if run.status.isLive { ProgressView().tint(BrandColor.accent) }
                Text(progress.headline)
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
            }
            if let detail = progress.detail {
                Text(detail)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            }
            ProgressView(value: progress.fraction)
                .tint(BrandColor.accent)
                .accessibilityHidden(true)
            if run.status.isLive {
                Text("You can close this — we’ll let you know when it’s ready.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textSecondary)
            }
            if run.retryable {
                threadButton(busy ? ConsultThreadCopy.planStarting : "Try again", action: onRetry)
            } else if !run.status.isLive {
                threadButton("Check results", action: onRefresh)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func threadButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(BrandFont.body(15, .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(BrandColor.onAccent)
                .background(BrandColor.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(busy)
    }
}
