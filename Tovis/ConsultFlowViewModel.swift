import Foundation
import Observation
import OSLog
import TovisKit
import UIKit

@MainActor
@Observable
final class ConsultFlowViewModel {
    private(set) var machine: ConsultFlowMachine
    private(set) var agreementState: ConsultAgreementState?
    private(set) var intakeState: ConsultIntakeState?
    private(set) var inspirationState: ConsultInspirationState?
    private(set) var captureState: ConsultCaptureState?
    private(set) var analysisState: ConsultAnalysisState?
    private(set) var results: ConsultClientResults?
    private(set) var answers: [String: String] = [:]
    private(set) var busy = false
    private(set) var processingShot: ConsultCaptureShotKey?
    private(set) var failure: ConsultClientFailure?
    private(set) var teaserTapped = false
    /// Local previews of this session's uploads. Rejected photos are purged
    /// server-side immediately, so this decoded copy is the only reviewable one.
    private(set) var localThumbnails: [ConsultCaptureShotKey: UIImage] = [:]

    let professionalId: String

    @ObservationIgnored private let service: any ConsultServicing
    @ObservationIgnored private var intakeIdempotencyKey = UUID().uuidString
    @ObservationIgnored private var analysisIdempotencyKey = UUID().uuidString
    @ObservationIgnored private var pendingPhoto: PendingPhoto?
    /// P4b: the live-run poll. Nil whenever nothing is being polled.
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    // Signed read URL for the inspiration image; short-lived, so refreshed
    // shortly before expiry instead of per render.
    @ObservationIgnored private var inspirationImageCache: (url: URL, expiresAt: Date)?

    private struct PendingPhoto {
        let shot: ConsultCaptureShot
        let data: Data
        let keys: ConsultCaptureMutationKeys
    }

    init(anchor: ConsultAnchor, professionalId: String,
         service: any ConsultServicing) {
        machine = ConsultFlowMachine(anchor: anchor)
        self.professionalId = professionalId
        self.service = service
    }

    var stage: ConsultFlowStage { machine.stage }

    /// The consult the flow is on, once the server has named it. Book the Look
    /// (B8) reads it to open the booking door from the results screen.
    var consultId: String? { machine.consultId }

    /// True when this flow was opened from a LOOK rather than from a booking —
    /// the only case where a booking DOOR belongs on the results screen.
    var isLookAnchored: Bool { machine.anchor.lookPostId != nil }

    /// Whether Continue is offered. The served `progress.canComplete` is the
    /// authority — it is the web wizard's gate and it knows the pack's
    /// goal-direction rule — but it describes the answers the server has SAVED,
    /// and this flow saves only on submit. So a served "cannot complete" is
    /// trusted only while nothing has changed locally; once the client has
    /// answered further, the local rule (REQUIRED answered) decides, and the
    /// server has the final word when the submit lands.
    var canSubmitIntake: Bool {
        guard let intakeState else { return false }
        let locallyComplete = intakeState.questionPack.questions.allSatisfy {
            !$0.requirement.mustAnswer || answers[$0.key] != nil
        }
        guard let served = intakeState.progress?.canComplete else { return locallyComplete }
        if answers == (intakeState.latestRevision?.answers ?? [:]) { return served }
        return locallyComplete
    }

    /// The service this consult is about, in the client's own language — the
    /// pro's offering title where they set one, the catalog name otherwise.
    /// Nil when the Look's linked service row is gone, which is a real state
    /// and reads as "your consult" rather than as a wrong service name.
    var intakeServiceName: String? {
        guard let name = intakeState?.service?.name?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !name.isEmpty else { return nil }
        return name
    }

    var intakeQuestionCount: Int {
        intakeState?.questionPack.questions.count ?? 0
    }

    var intakeAnsweredCount: Int {
        intakeState?.questionPack.questions.filter { answers[$0.key] != nil }.count ?? 0
    }

    /// The ONE question on screen, and the same rule the web wizard uses: the
    /// server's `progress.nextQuestionKey` where it still applies, otherwise
    /// the first question with no answer.
    ///
    /// Why the served key cannot simply be trusted throughout: it describes the
    /// answers the server has SAVED, and this flow saves once, on submit. Left
    /// alone it would pin the screen to the first question while the client
    /// answered the whole pack. So it is authoritative only while local answers
    /// still match the saved ones (the same trust boundary `canSubmitIntake`
    /// draws); after that the pack's own order decides — required questions
    /// first, then anything else unanswered, which is what surfaces the
    /// conditional goal-direction question exactly where the web wizard
    /// surfaces it.
    ///
    /// Nil means every question has an answer: the step is done, and the
    /// Continue button takes its place.
    var intakeQuestion: ConsultIntakeQuestion? {
        guard let questions = intakeState?.questionPack.questions else { return nil }
        if answers == (intakeState?.latestRevision?.answers ?? [:]),
           let servedKey = intakeState?.progress?.nextQuestionKey,
           let served = questions.first(where: { $0.key == servedKey }) {
            return served
        }
        return questions.first { $0.requirement.mustAnswer && answers[$0.key] == nil }
            ?? questions.first { answers[$0.key] == nil }
    }

    var canRetryPhoto: Bool { pendingPhoto != nil && !busy }

    var inspirationDone: Bool { inspirationState?.isComplete ?? false }

    var acceptedShotCount: Int {
        captureState?.slots.filter { $0.state == .accepted }.count ?? 0
    }

    var totalShotCount: Int { captureState?.shotPack.shots.count ?? 0 }

    /// The partial-pack affordance: some but not all photos accepted while the
    /// session still sits at MEDIA_READY. (A full accepted pack advances
    /// server-side on its own once inspiration is done.)
    var canOfferPartialContinue: Bool {
        guard let capture = captureState, capture.status == .mediaReady else { return false }
        return acceptedShotCount >= 1 && acceptedShotCount < totalShotCount
    }

    // Exposure is server-decided (GET /client/consult/availability gates the
    // entry point; every consult route 404s while the pilot is dark for this
    // pro), so entry carries no device-side copy of the founder gate. The one
    // local check left is the booking/pro pairing contract.
    func start() async {
        await perform {
            // Create-or-resume, on the SERVER, for both anchors: asking twice
            // returns the SAME consult rather than a second one.
            let consultId: String
            switch machine.anchor {
            case let .booking(bookingId):
                let session = try await service.create(bookingId: bookingId)
                guard session.professionalId == professionalId else {
                    throw ConsultClientFailure.hidden
                }
                try machine.apply(session: session)
                consultId = session.id
            case let .look(lookPostId):
                let session = try await service.createFromLook(lookPostId: lookPostId)
                guard session.professionalId == professionalId else {
                    throw ConsultClientFailure.hidden
                }
                try machine.apply(lookSession: session)
                consultId = session.id
            }
            let agreements = try await service.agreements(consultId: consultId)
            agreementState = agreements
            try machine.apply(agreements: agreements)
            try await loadCurrentStage(consultId: consultId)
        }
    }

    func accept(_ requirement: ConsultAgreementRequirement) async {
        guard let consultId = machine.consultId else { return }
        await perform {
            let state = try await service.acceptAgreement(
                consultId: consultId,
                kind: requirement.kind,
                agreementVersionId: requirement.requiredVersion.id
            )
            agreementState = state
            try machine.apply(agreements: state)
            if state.allCurrent { try await loadIntake(consultId: consultId) }
        }
    }

    func revokeSensitiveConsent() async {
        guard let consultId = machine.consultId,
              let acceptance = agreementState?.requirements.first(where: {
                  $0.kind == .sensitiveDataConsent
              })?.currentAcceptance else { return }
        await perform {
            let state = try await service.revokeAgreement(
                consultId: consultId,
                acceptanceId: acceptance.id
            )
            pendingPhoto = nil
            localThumbnails = [:]
            inspirationImageCache = nil
            agreementState = state
            try machine.apply(agreements: state)
            // She asked for this one. Show the full stop, not an immediate
            // request to accept again — tapping Book later is what offers the
            // way back in (ConsultFlowMachine.stopAfterRevoke).
            if state.status == .consentRevoked { machine.stopAfterRevoke() }
        }
    }

    func selectAnswer(questionKey: String, value: String) {
        guard intakeState?.questionPack.questions.contains(where: {
            $0.key == questionKey && $0.options.contains(where: { $0.value == value })
        }) == true else { return }
        if answers[questionKey] != value {
            answers[questionKey] = value
            intakeIdempotencyKey = UUID().uuidString
        }
        failure = nil
    }

    func submitIntake() async {
        guard canSubmitIntake, let consultId = machine.consultId,
              let intakeState else { return }
        await perform {
            let updated = try await service.submitIntake(
                consultId: consultId,
                state: intakeState,
                answers: answers,
                idempotencyKey: intakeIdempotencyKey
            )
            self.intakeState = updated
            try machine.apply(intake: updated)
            try await loadMediaStage(consultId: consultId)
        }
    }

    // MARK: - Inspiration

    func skipInspiration() async {
        guard let consultId = machine.consultId,
              let inspiration = inspirationState else { return }
        await perform {
            let state = try await service.skipInspiration(
                consultId: consultId,
                schemaVersion: inspiration.schemaVersion,
                idempotencyKey: UUID().uuidString
            )
            try await apply(inspiration: state, consultId: consultId)
        }
    }

    func uploadInspirationPhoto(_ jpegData: Data) async {
        guard let consultId = machine.consultId,
              let inspiration = inspirationState else { return }
        await perform {
            let state = try await service.uploadInspiration(
                consultId: consultId,
                schemaVersion: inspiration.schemaVersion,
                jpegData: jpegData,
                keys: ConsultInspirationMutationKeys()
            )
            inspirationImageCache = nil
            try await apply(inspiration: state, consultId: consultId)
        }
    }

    func answerInspiration(
        question: ConsultInspirationQuestion,
        selectedValues: [String],
        text: String,
        sentiment: ConsultInspirationSentiment?
    ) async {
        guard let consultId = machine.consultId,
              let inspiration = inspirationState else { return }
        let trimmed = question.allowText
            ? text.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let values = ConsultInspirationAnswering.effectiveValues(
            question: question, selected: selectedValues, trimmedText: trimmed
        )
        await perform {
            let state = try await service.answerInspiration(
                consultId: consultId,
                schemaVersion: inspiration.schemaVersion,
                questionKey: question.key,
                selectedValues: values,
                text: trimmed.isEmpty ? nil : trimmed,
                sentiment: trimmed.isEmpty ? nil : sentiment,
                idempotencyKey: UUID().uuidString
            )
            try await apply(inspiration: state, consultId: consultId)
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
              let source = inspirationState?.source, source.imageAvailable else {
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

    func proceedWithAccepted() async {
        guard let consultId = machine.consultId else { return }
        await perform {
            let capture = try await service.proceedWithAccepted(consultId: consultId)
            captureState = capture
            try machine.apply(capture: capture)
            try await loadAnalysisIfEntered(consultId: consultId)
        }
    }

    func submitPhoto(_ data: Data, for shot: ConsultCaptureShot) async {
        pendingPhoto = PendingPhoto(shot: shot, data: data, keys: ConsultCaptureMutationKeys())
        // Decode the reviewable thumbnail before the upload: a rejected photo
        // is purged server-side instantly, so this local copy is the only way
        // to look at what the quality check refused.
        if let thumbnail = await ImageDownsample.thumbnail(from: data, maxPixel: 432) {
            localThumbnails[shot.key] = thumbnail
        }
        await sendPendingPhoto()
    }

    /// Records the client's chart-copy choice (default-on but visibly
    /// optional; changeable until analysis runs).
    func setChartCopy(_ optIn: Bool) async {
        guard let consultId = machine.consultId else { return }
        await perform {
            let capture = try await service.setChartCopy(consultId: consultId, optIn: optIn)
            captureState = capture
            try machine.apply(capture: capture)
        }
    }

    func retryPhoto() async { await sendPendingPhoto() }

    private func sendPendingPhoto() async {
        guard let pendingPhoto, let consultId = machine.consultId,
              let pack = captureState?.shotPack else { return }
        processingShot = pendingPhoto.shot.key
        await perform {
            let response = try await service.uploadAndCheckCapture(
                consultId: consultId,
                shot: pendingPhoto.shot,
                pack: pack,
                jpegData: pendingPhoto.data,
                keys: pendingPhoto.keys
            )
            self.pendingPhoto = nil
            captureState = response.capture
            try machine.apply(capture: response.capture)
            // The last accepted shot of a complete pack advances the session
            // server-side; follow it into the analysis stage.
            try await loadAnalysisIfEntered(consultId: consultId)
        }
        processingShot = nil
    }

    /// P4b: START the analysis. The request claims it and returns a run in a
    /// fraction of a second; everything after that is `pollAnalysis` below.
    ///
    /// This is also the RETRY: the server keeps the session in ANALYZING and
    /// starts a fresh run, under the SAME idempotency key — the artefact a
    /// retried run writes is the artefact the first attempt would have written.
    func startAnalysis() async {
        guard let consultId = machine.consultId else { return }
        await perform {
            let analysis = try await service.startAnalysis(
                consultId: consultId,
                idempotencyKey: analysisIdempotencyKey
            )
            analysisState = analysis
            try machine.apply(analysis: analysis)
            if analysis.status == .completed { try await loadResults(consultId: consultId) }
        }
        startPollingIfLive()
    }

    func refreshAnalysis() async {
        guard let consultId = machine.consultId else { return }
        await perform {
            let analysis = try await service.analysis(consultId: consultId)
            analysisState = analysis
            try machine.apply(analysis: analysis)
            if analysis.status == .completed { try await loadResults(consultId: consultId) }
        }
        startPollingIfLive()
    }

    // MARK: - The poll (P4b)

    /// Begin polling if — and only if — there is a live run to poll.
    ///
    /// Idempotent: a second call while a poll is already running is a no-op, so
    /// every entry point into the analysis stage can call it without
    /// coordinating. `stopPolling` is called from the view's `onDisappear`, so
    /// a backgrounded or navigated-away screen stops asking.
    func startPollingIfLive() {
        guard pollTask == nil else { return }
        guard let run = analysisState?.run, run.status.isLive else { return }
        guard let consultId = machine.consultId else { return }

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
    /// Deliberately does NOT go through `perform`: that sets `busy`, which
    /// drives the spinner and the disabled state on the buttons, and a poll is
    /// background work the client did not initiate. It also swallows its own
    /// errors — a dropped poll is not a failed analysis, the run is still going
    /// on the server, and the next tick asks again. Surfacing a network blip
    /// here would tell her something is wrong when nothing is.
    private func pollOnce(consultId: String) async -> Bool {
        do {
            let analysis = try await service.analysis(consultId: consultId)
            analysisState = analysis
            try machine.apply(analysis: analysis)
            if analysis.status == .completed {
                try await loadResults(consultId: consultId)
                pollTask = nil
                return true
            }
            if let run = analysis.run, !run.status.isLive {
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

    private func loadCurrentStage(consultId: String) async throws {
        switch machine.stage {
        case .prerequisites, .stopped:
            return
        case .intake:
            try await loadIntake(consultId: consultId)
        case .capture:
            try await loadMediaStage(consultId: consultId)
        case .analysis:
            let analysis = try await service.analysis(consultId: consultId)
            analysisState = analysis
            try machine.apply(analysis: analysis)
            if analysis.status == .completed { try await loadResults(consultId: consultId) }
            // A cold launch straight into a running analysis — the client left
            // and came back — has to resume polling, or the screen sits on
            // whatever stage it happened to load.
            startPollingIfLive()
        case .results:
            try await loadResults(consultId: consultId)
        }
    }

    /// MEDIA_READY covers both the inspiration review and the photo pack —
    /// load them together, the way the web wizard renders them together.
    private func loadMediaStage(consultId: String) async throws {
        let inspiration = try await service.inspiration(consultId: consultId)
        inspirationState = inspiration
        try machine.apply(inspiration: inspiration)
        let capture = try await service.capture(consultId: consultId)
        captureState = capture
        try machine.apply(capture: capture)
        try await loadAnalysisIfEntered(consultId: consultId)
    }

    /// An inspiration mutation can complete the review and, with a full
    /// accepted pack, advance the whole session — bind the returned state and
    /// follow any stage change.
    private func apply(inspiration: ConsultInspirationState, consultId: String) async throws {
        inspirationState = inspiration
        try machine.apply(inspiration: inspiration)
        try await loadAnalysisIfEntered(consultId: consultId)
    }

    private func loadAnalysisIfEntered(consultId: String) async throws {
        guard machine.stage == .analysis, analysisState == nil else { return }
        let analysis = try await service.analysis(consultId: consultId)
        analysisState = analysis
        try machine.apply(analysis: analysis)
        if analysis.status == .completed { try await loadResults(consultId: consultId) }
        startPollingIfLive()
    }

    private func loadIntake(consultId: String) async throws {
        let intake = try await service.intake(consultId: consultId)
        intakeState = intake
        var seeded = intake.latestRevision?.answers ?? [:]
        for suggestion in intake.prefillSuggestions where seeded[suggestion.questionKey] == nil {
            seeded[suggestion.questionKey] = suggestion.value
        }
        answers = seeded
        try machine.apply(intake: intake)
    }

    private func loadResults(consultId: String) async throws {
        let loaded = try await service.results(consultId: consultId)
        try machine.apply(results: loaded)
        results = loaded
        teaserTapped = loaded.meCardTeaser.tapped
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do {
            try await operation()
        } catch {
            failure = ConsultClientFailure.stable(error)
        }
    }
}
