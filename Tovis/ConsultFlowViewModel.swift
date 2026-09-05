import Foundation
import Observation
import OSLog
import TovisKit
import UIKit

/// P5a — the consult, driven as a THREAD.
///
/// ONE read owns the screen: `GET /client/consult/{id}/thread` serves the whole
/// flow state as an ordered message list plus `nextOpenMessageId`, so "reopening
/// a consult resumes at the next open step" is the server's answer rather than
/// four progress blockers re-interpreted here. Every mutation below still goes
/// through the SAME per-stage endpoint it always did — those contracts are
/// untouched — and then re-reads the thread.
///
/// 🔴 Two things survived the rewrite deliberately, and must keep surviving:
///
///   * the durable upload queue (P2d). `submitPhoto` still writes bytes to the
///     vault and hands them to `ConsultCaptureUploadQueue`, which owns them
///     through the camera closing, the app backgrounding and the process being
///     killed. The thread renders the SERVED slot; the queue's own stage
///     outranks it, because the queue knows about a shot the server has not been
///     told about yet.
///   * the C7 results provenance check. Results now arrive inside a thread
///     message instead of from `GET /results`, and a payload that skipped
///     `ConsultFlowMachine.apply(results:)` would be rendered with none of its
///     anchor and revision checks run. `bind(threadResults:)` below is where
///     that check still happens.
@MainActor
@Observable
final class ConsultFlowViewModel {
    private(set) var machine: ConsultFlowMachine
    /// The whole screen, in one value.
    private(set) var thread: ConsultThread?
    private(set) var busy = false
    /// The durable owner of every shot this flow has taken. `.shared` in the
    /// app — one queue for the whole process, deliberately outliving every
    /// flow — and injectable so tests can drive it without a live client.
    @ObservationIgnored let uploads: ConsultCaptureUploadQueue
    private(set) var failure: ConsultClientFailure?
    private(set) var teaserTapped = false
    /// Local previews of this session's uploads. Rejected photos are purged
    /// server-side immediately, so this decoded copy is the only reviewable one.
    private(set) var localThumbnails: [ConsultCaptureShotKey: UIImage] = [:]
    /// True when a results payload failed the provenance check — rendered as a
    /// refusal, never as a missing section.
    private(set) var resultsContractMismatch = false

    let professionalId: String

    @ObservationIgnored private let service: any ConsultServicing
    @ObservationIgnored private var analysisIdempotencyKey = UUID().uuidString
    /// The tail of the serial queue `perform` forms. Nil when nothing is running.
    @ObservationIgnored private var performTail: Task<Void, Never>?
    /// P4b: the live-run poll. Nil whenever nothing is being polled.
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    // Signed read URL for the inspiration image; short-lived, so refreshed
    // shortly before expiry instead of per render.
    @ObservationIgnored private var inspirationImageCache: (url: URL, expiresAt: Date)?

    init(anchor: ConsultAnchor, professionalId: String,
         service: any ConsultServicing,
         // Optional rather than `= .shared`: a default argument is evaluated in
         // a NONISOLATED context, and reading a main-actor static from there is
         // an error in the Swift 6 language mode. Resolved in the body instead,
         // which is main-actor isolated like the rest of this type.
         uploads: ConsultCaptureUploadQueue? = nil) {
        machine = ConsultFlowMachine(anchor: anchor)
        self.professionalId = professionalId
        self.service = service
        self.uploads = uploads ?? .shared
    }

    /// The consult the flow is on, once the server has named it.
    var consultId: String? { machine.consultId }

    /// True when this flow was opened from a LOOK rather than from a booking.
    var isLookAnchored: Bool { machine.anchor.lookPostId != nil }

    var messages: [ConsultThreadMessage] { thread?.messages ?? [] }
    var nextOpenMessageId: String? { thread?.nextOpenMessageId }
    var professionalDisplayName: String { thread?.professionalDisplayName ?? "" }

    /// A consult that can no longer be worked on. The thread still renders — it
    /// carries its own explanation — but nothing in it is actionable.
    var isStopped: Bool { thread?.status == .cancelled }

    // MARK: - Capture chrome, off the durable queue

    /// What the queue is saying about this consult right now, for the one line
    /// under the photo requests. Nil when everything is healthy.
    var captureQueueMessage: String? {
        guard let consultId = machine.consultId,
              uploads.owesAnything(consultId: consultId) else { return nil }
        return uploads.statusMessage
    }

    /// Where the queue has got to with one slot, if it owes anything for it.
    func captureStage(for shotKey: ConsultCaptureShotKey) -> ConsultCaptureStage? {
        guard let consultId = machine.consultId else { return nil }
        return uploads.stage(consultId: consultId, shotKey: shotKey)
    }

    func captureBlockedReason(for shotKey: ConsultCaptureShotKey) -> String? {
        guard let consultId = machine.consultId else { return nil }
        return uploads.blockedReason(consultId: consultId, shotKey: shotKey)
    }

    /// Whether anything is owed that a tap could usefully retry. True while the
    /// queue is stalled on a connection as well as when a shot was refused —
    /// both are states the client can act on, and neither is `busy`.
    var canRetryPhoto: Bool {
        guard let consultId = machine.consultId, uploads.owesAnything(consultId: consultId)
        else { return false }
        return uploads.stalled || uploads.hasBlocked(consultId: consultId)
    }

    private var photoMessages: [ConsultThreadMessage] {
        messages.filter { $0.kind == .photoRequest }
    }

    var acceptedShotCount: Int {
        photoMessages.filter { $0.slot?.state == .accepted }.count
    }

    var totalShotCount: Int { photoMessages.count }

    /// The partial-pack affordance: some but not all photos accepted while the
    /// session still sits at MEDIA_READY. (A full accepted pack advances
    /// server-side on its own once inspiration is done.)
    var canOfferPartialContinue: Bool {
        guard thread?.status == .mediaReady else { return false }
        return acceptedShotCount >= 1 && acceptedShotCount < totalShotCount
    }

    var chartCopy: ConsultChartCopyState? { thread?.chartCopy }

    // MARK: - Lifecycle

    // Exposure is server-decided (GET /client/consult/availability gates the
    // entry point; every consult route 404s while the pilot is dark for this
    // pro), so entry carries no device-side copy of the founder gate. The one
    // local check left is the booking/pro pairing contract.
    func start() async {
        bindUploads()
        await perform {
            // Create-or-resume, on the SERVER, for both anchors: asking twice
            // returns the SAME consult rather than a second one.
            switch machine.anchor {
            case let .booking(bookingId):
                let session = try await service.create(bookingId: bookingId)
                guard session.professionalId == professionalId else {
                    throw ConsultClientFailure.hidden
                }
                try machine.apply(session: session)
            case let .look(lookPostId):
                let session = try await service.createFromLook(lookPostId: lookPostId)
                guard session.professionalId == professionalId else {
                    throw ConsultClientFailure.hidden
                }
                try machine.apply(lookSession: session)
            }
            try await loadThread()
        }
        startPollingIfLive()
    }

    /// The one read. Everything on screen comes from it.
    private func loadThread() async throws {
        guard let consultId = machine.consultId else { return }
        let served = try await service.thread(consultId: consultId)
        bind(thread: served)
    }

    /// Re-read after a mutation, and after a queue leg lands.
    ///
    /// Deliberately outside `perform` when called from the queue: it is
    /// background work the client did not initiate, so it must not raise the
    /// spinner or disable her buttons, and a dropped refresh is not a failure
    /// worth a banner.
    func refreshThread() async {
        do { try await loadThread() } catch {
            ConsultCaptureTelemetry.queue("state_refresh_failed", level: .warning)
        }
    }

    /// Bind a served thread, running the checks the per-stage applies used to.
    ///
    /// 🔴 The results provenance check is the load-bearing half. Before P5a,
    /// results reached the screen through `ConsultFlowMachine.apply(results:)`,
    /// which refuses a payload whose anchor, service category or revision ids do
    /// not match the flow it was opened on — the check that stops one client's
    /// analysis rendering inside another's consult. Results now ride on a thread
    /// message, so the same check is run here or it is not run at all.
    private func bind(thread served: ConsultThread) {
        if let results = served.messages.first(where: { $0.kind == .plan })?.results {
            do {
                try machine.apply(results: results)
                resultsContractMismatch = false
            } catch {
                // Refuse the PLAN's contents, keep the rest of the thread. A
                // consult whose results cannot be trusted still has its own
                // history, and the client is TOLD rather than shown a section
                // that quietly vanished.
                //
                // The flag is what the view reads; the message is left intact on
                // purpose, because rebuilding a decoded wire struct to blank one
                // field would be a second, hand-maintained copy of the thread
                // shape — and a rendering rule belongs in the renderer.
                resultsContractMismatch = true
                thread = served
                return
            }
        }
        resultsContractMismatch = false
        thread = served
    }

    // MARK: - Consent

    func accept(_ requirement: ConsultAgreementRequirement) async {
        guard let consultId = machine.consultId else { return }
        await perform {
            let state = try await service.acceptAgreement(
                consultId: consultId,
                kind: requirement.kind,
                agreementVersionId: requirement.requiredVersion.id
            )
            try machine.apply(agreements: state)
            try await loadThread()
        }
    }

    func revokeSensitiveConsent() async {
        guard let consultId = machine.consultId,
              let acceptance = messages
                  .first(where: { $0.kind == .consent })?
                  .requirements?
                  .first(where: { $0.kind == .sensitiveDataConsent })?
                  .currentAcceptance
        else { return }
        await perform {
            let state = try await service.revokeAgreement(
                consultId: consultId, acceptanceId: acceptance.id
            )
            try machine.apply(agreements: state)
            machine.stopAfterRevoke()
            try await loadThread()
        }
    }

    /// Whether the privacy/revoke footer belongs on screen: only once consent is
    /// actually current, and never on a consult that has already stopped.
    var canRevokeConsent: Bool {
        guard !isStopped else { return false }
        guard let consent = messages.first(where: { $0.kind == .consent }) else { return false }
        return consent.state == .done
    }

    // MARK: - Intake

    /// One tap answers one question, and the POST carries the WHOLE revision —
    /// so the answers already in the thread are read back out of it rather than
    /// kept in a second copy here that could drift from what the server holds.
    func answerIntake(_ message: ConsultThreadMessage, value: String) async {
        guard let consultId = machine.consultId,
              let question = message.question,
              let packVersion = message.packVersion,
              let schemaVersion = message.schemaVersion,
              question.options.contains(where: { $0.value == value })
        else { return }

        var answers: [String: String] = [:]
        for entry in messages where entry.kind == .question {
            if let key = entry.question?.key, let existing = entry.answer {
                answers[key] = existing
            }
        }
        answers[question.key] = value

        // `complete` is the server's own judgement, echoed: every REQUIRED
        // question now has an answer. Claiming it early is refused; claiming it
        // late leaves the client on a step with no way forward.
        let complete = messages
            .filter { $0.kind == .question && $0.question?.requirement.mustAnswer == true }
            .allSatisfy { entry in
                guard let key = entry.question?.key else { return true }
                return answers[key] != nil
            }

        await perform {
            _ = try await service.submitIntake(
                consultId: consultId,
                packVersion: packVersion,
                schemaVersion: schemaVersion,
                answers: answers,
                complete: complete,
                idempotencyKey: UUID().uuidString
            )
            try await loadThread()
        }
    }

    // MARK: - Inspiration

    func skipInspiration(_ message: ConsultThreadMessage) async {
        guard let consultId = machine.consultId,
              let schemaVersion = message.schemaVersion else { return }
        await perform {
            _ = try await service.skipInspiration(
                consultId: consultId,
                schemaVersion: schemaVersion,
                idempotencyKey: UUID().uuidString
            )
            try await loadThread()
        }
    }

    func uploadInspirationPhoto(_ message: ConsultThreadMessage, _ jpegData: Data) async {
        guard let consultId = machine.consultId,
              let schemaVersion = message.schemaVersion else { return }
        await perform {
            _ = try await service.uploadInspiration(
                consultId: consultId,
                schemaVersion: schemaVersion,
                jpegData: jpegData,
                keys: ConsultInspirationMutationKeys()
            )
            inspirationImageCache = nil
            try await loadThread()
        }
    }

    /// 🔴 No free text reaches this call, by construction: the thread has no
    /// text input at all (P5a). Nothing is lost from the contract — every
    /// question that allowed a note also carries a tappable option, and the
    /// server treats a blank note as that option.
    func answerInspiration(
        _ message: ConsultThreadMessage,
        question: ConsultInspirationQuestion,
        selectedValues: [String]
    ) async {
        guard let consultId = machine.consultId,
              let schemaVersion = message.schemaVersion else { return }
        let values = ConsultInspirationAnswering.effectiveValues(
            question: question, selected: selectedValues, trimmedText: ""
        )
        await perform {
            _ = try await service.answerInspiration(
                consultId: consultId,
                schemaVersion: schemaVersion,
                questionKey: question.key,
                selectedValues: values,
                text: nil,
                sentiment: nil,
                idempotencyKey: UUID().uuidString
            )
            try await loadThread()
        }
    }

    /// What the inspiration panel got back for its image.
    ///
    /// Three OUTCOMES, not two: "there is no image to show" and "there is one
    /// and we could not load it" are different things the client is owed
    /// different words for. Collapsing both into `nil` is what let B4 ship —
    /// a look-anchored consult rendered an empty panel and told nobody.
    enum InspirationImageOutcome: Equatable {
        case unavailable
        case ready(URL)
        case failed
    }

    /// Read URL for the inspiration photo — the client's upload OR the
    /// anchoring Look, both behind the one `imageReadEndpoint` route — fetched
    /// lazily and renewed shortly before it expires so the image never goes
    /// dark mid-question.
    ///
    /// 🔴 A read that fails returns `.failed` and logs it. It must NEVER be
    /// swallowed into "no image": the panel is the whole point of the
    /// likes/dislikes step, and a silent blank is indistinguishable from a
    /// feature that was never built.
    func inspirationImage() async -> InspirationImageOutcome {
        guard let consultId = machine.consultId,
              let source = messages.first(where: { $0.kind == .inspiration })?.source,
              source.imageAvailable else {
            return .unavailable
        }
        if let cached = inspirationImageCache,
           cached.expiresAt.timeIntervalSinceNow > 60 {
            return .ready(cached.url)
        }
        do {
            let read = try await service.inspirationImage(
                consultId: consultId, readEndpoint: source.imageReadEndpoint
            )
            guard let url = URL(string: read.url) else {
                Self.logInspirationImageReadFailure(
                    source: source.source, reason: "MALFORMED_URL"
                )
                return .failed
            }
            inspirationImageCache = (url, Date().addingTimeInterval(read.expiresInSeconds))
            return .ready(url)
        } catch {
            Self.logInspirationImageReadFailure(
                source: source.source,
                reason: (error as? ConsultClientFailure) == .contractMismatch
                    ? "CONTRACT_MISMATCH"
                    : "REQUEST_FAILED"
            )
            return .failed
        }
    }

    nonisolated private static let consultLog = Logger(
        subsystem: "app.tovis", category: "consult"
    )

    /// Telemetry twin of web's `consult.inspiration.image_read_failed`. The
    /// inspiration SOURCE and a coarse reason only — no consult id, no URL, no
    /// signed token, nothing about the client.
    nonisolated private static func logInspirationImageReadFailure(
        source: String, reason: String
    ) {
        consultLog.error(
            "ai_consult INSPIRATION_IMAGE_READ_FAILED source=\(source, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    // MARK: - Photos

    func proceedWithAccepted() async {
        guard let consultId = machine.consultId else { return }
        await perform {
            _ = try await service.proceedWithAccepted(consultId: consultId)
            try await loadThread()
        }
    }

    /// Hand one shot to the durable queue.
    ///
    /// 🔴 This does NOT run the upload chain, and that is the whole of P2d. The
    /// bytes are written to `SessionByteVault` before this returns, and
    /// `ConsultCaptureUploadQueue` owns them from there — through the camera
    /// being dismissed, the app being backgrounded, and the process being
    /// killed. There is deliberately no `perform` here either: `perform`'s
    /// `guard !busy` silently DROPPED a second shot fired while the first was in
    /// flight, and a queue exists precisely so a second shot is queued instead.
    ///
    /// The pack versions come from the photo-request MESSAGE rather than from a
    /// separately loaded capture state — one read, and the versions travel with
    /// the shot they belong to.
    func submitPhoto(_ data: Data, for message: ConsultThreadMessage) async {
        guard let consultId = machine.consultId,
              let shot = message.shot,
              let shotPackVersion = message.shotPackVersion,
              let schemaVersion = message.schemaVersion else {
            failure = .invalidState
            return
        }
        // Decode the reviewable thumbnail first: a rejected photo is purged
        // server-side instantly, so this local copy is the only way to look at
        // what the quality check refused.
        if let thumbnail = await ImageDownsample.thumbnail(from: data, maxPixel: 432) {
            localThumbnails[shot.key] = thumbnail
        }
        guard let item = SessionByteVault.writeConsultCapture(
            data,
            consultId: consultId,
            shotKey: shot.key,
            shotPackVersion: shotPackVersion,
            schemaVersion: schemaVersion,
            capturedAt: Date()
        ) else {
            // Nowhere to put the bytes is a real failure, and the one thing that
            // must never happen quietly — an unwritable vault would put us back
            // to holding photographs in RAM.
            ConsultCaptureTelemetry.stage(
                .queued, outcome: .abandoned, shotKey: shot.key,
                consultId: consultId, detail: "vault_write_failed"
            )
            failure = .invalidPhoto
            return
        }
        uploads.enqueue(item)
    }

    /// Records the client's chart-copy choice (default-on but visibly
    /// optional; changeable until analysis runs).
    func setChartCopy(_ optIn: Bool) async {
        guard let consultId = machine.consultId else { return }
        await perform {
            _ = try await service.setChartCopy(consultId: consultId, optIn: optIn)
            try await loadThread()
        }
    }

    /// The client asking for one more honest attempt at everything still owed —
    /// including shots the server refused.
    func retryPhoto() async {
        await uploads.retryNow()
    }

    // MARK: - Analysis (P4b)

    /// START the analysis. The request claims it and returns a run in a fraction
    /// of a second; everything after that is `pollOnce` below.
    ///
    /// This is also the RETRY: the server keeps the session in ANALYZING and
    /// starts a fresh run, under the SAME idempotency key — the artefact a
    /// retried run writes is the artefact the first attempt would have written.
    func startAnalysis() async {
        guard let consultId = machine.consultId else { return }
        await perform {
            _ = try await service.startAnalysis(
                consultId: consultId,
                idempotencyKey: analysisIdempotencyKey
            )
            try await loadThread()
        }
        startPollingIfLive()
    }

    func refreshAnalysis() async {
        await perform { try await loadThread() }
        startPollingIfLive()
    }

    private var liveRun: ConsultAnalysisRun? {
        guard let run = messages.first(where: { $0.kind == .plan })?.run,
              run.status.isLive else { return nil }
        return run
    }

    /// Begin polling if — and only if — there is a live run to poll.
    ///
    /// Idempotent: a second call while a poll is already running is a no-op, so
    /// every entry point can call it without coordinating. `stopPolling` is
    /// called from the view's `onDisappear`, so a screen nobody is looking at
    /// stops asking.
    func startPollingIfLive() {
        guard pollTask == nil, liveRun != nil, let consultId = machine.consultId else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ConsultAnalysisRunCopy.pollInterval)
                if Task.isCancelled { return }
                guard let self else { return }
                let finished = await self.pollOnce(consultId: consultId)
                if finished { return }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Drive exactly one poll tick. The timing of the loop is not the thing
    /// worth testing — five real seconds per assertion would be — but what a
    /// tick DOES is, so the tick is reachable and the loop is not.
    @discardableResult
    func pollOnceForTest() async -> Bool {
        guard let consultId = machine.consultId else { return true }
        return await pollOnce(consultId: consultId)
    }

    /// One tick. Returns true when the run has settled and polling should stop.
    ///
    /// Deliberately does NOT go through `perform`: that sets `busy`, which drives
    /// the spinner and the disabled state on the buttons, and a poll is
    /// background work the client did not initiate. It also swallows its own
    /// errors — a dropped poll is not a failed analysis, the run is still going
    /// on the server, and the next tick asks again.
    ///
    /// 🔴 A completed run does NOT navigate away. The plan lands in the thread
    /// and the thread stays open — that is the difference between a wizard that
    /// ends and a consult that continues as prep.
    private func pollOnce(consultId: String) async -> Bool {
        do {
            let served = try await service.thread(consultId: consultId)
            bind(thread: served)
            if liveRun == nil {
                pollTask = nil
                return true
            }
            return false
        } catch {
            return false
        }
    }

    func tapLockedMeCard() async {
        guard let consultId = machine.consultId, !teaserTapped else { return }
        await perform {
            try await service.recordLockedTeaserTap(consultId: consultId)
            teaserTapped = true
        }
    }

    func clearFailure() { failure = nil }

    /// Let the durable queue tell this flow when a leg has landed, so the thread
    /// re-reads the server instead of waiting for the client to do something.
    /// `[weak self]` on purpose: the queue outlives every flow, and a strong
    /// closure would pin a dismissed one forever. Only the consult on screen
    /// refreshes — a leg landing for a different consult is the queue's
    /// business, not this screen's.
    private func bindUploads() {
        uploads.onStageCompleted = { [weak self] consultId in
            guard let self, self.machine.consultId == consultId else { return }
            Task { await self.refreshThread() }
        }
    }

    /// Serialize the client's own actions, and surface exactly one failure.
    ///
    /// 🔴 It QUEUES, it does not drop. A `guard !busy` here would silently
    /// discard a second action fired while the first was in flight — which is
    /// precisely why `submitPhoto` deliberately does not route through this at
    /// all, and why a rewrite that swapped this for a busy-guard would
    /// reintroduce the dropped-shot bug the durable queue exists to prevent.
    private func perform(_ operation: () async throws -> Void) async {
        let ahead = performTail
        // `mine` finishes when — and only when — this call finishes, so whoever
        // queues behind it waits for exactly that. An AsyncStream rather than a
        // continuation because a stream cannot be resumed twice, and because the
        // operation stays non-escaping this way.
        let (stream, ticket) = AsyncStream<Void>.makeStream()
        let mine = Task<Void, Never> { for await _ in stream {} }
        performTail = mine
        await ahead?.value

        busy = true
        failure = nil
        defer {
            busy = false
            ticket.finish()
            if performTail == mine { performTail = nil }
        }
        do {
            try await operation()
        } catch {
            failure = ConsultClientFailure.stable(error)
        }
    }
}
