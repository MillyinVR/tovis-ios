import Foundation
import Testing
import TovisKit
@testable import Tovis

private actor MockConsultService: ConsultServicing {
    private let root: [String: Any]
    private var acceptedKinds: Set<ConsultAgreementKind> = []
    private var acceptedShots: Set<ConsultCaptureShotKey> = []
    private var rejectedBackOnce = false
    private var inspirationSource: String?
    private var inspirationAnsweredCount = 0
    private var proceededWithPartialPack = false
    private var analysisStarted = false
    private(set) var captureKeys: [ConsultCaptureMutationKeys] = []
    private(set) var receivedByteCounts: [Int] = []
    private(set) var inspirationUploadByteCounts: [Int] = []
    private(set) var answeredInspirationKeys: [String] = []
    private(set) var teaserRecorded = false
    private(set) var consentRevoked = false
    var sessionProfessionalId = "cmq9p645v0002jp04fttoatlq"

    /// When set, `create` throws it — models the server hiding the consult
    /// (the pilot dark for this pro answers 404 on every consult route).
    var createError: Error?

    init(root: [String: Any]) { self.root = root }

    func availability(bookingId: String) async throws -> ConsultAvailability {
        ConsultAvailability(available: createError == nil, consult: nil)
    }

    // The mock mirrors the server's advance rule: ANALYSIS_PENDING requires a
    // complete inspiration review AND either every shot accepted or an
    // explicit partial-pack proceed.
    private var inspirationComplete: Bool {
        inspirationSource == "NONE"
            || (inspirationSource != nil && inspirationAnsweredCount >= 7)
    }

    private var sessionAdvancedToAnalysis: Bool {
        inspirationComplete
            && (acceptedShots.count == ConsultCaptureShotKey.hairPack.count
                || proceededWithPartialPack)
    }

    func create(bookingId: String) async throws -> ConsultSession {
        if let createError { throw createError }
        var value = dictionary("session", "consult")
        value["professionalId"] = sessionProfessionalId
        return try decode(ConsultSession.self, value: value)
    }

    // Book the Look, B8 — the look-anchored twins. `createFromLook` models the
    // server's create-or-resume: asking twice returns the SAME consult.
    func lookAvailability(lookPostId: String) async throws -> ConsultLookAvailability {
        ConsultLookAvailability(
            available: createError == nil, reason: nil, consult: nil)
    }

    func createFromLook(lookPostId: String) async throws -> ConsultLookSession {
        if let createError { throw createError }
        var value = dictionary("lookSession", "consult")
        value["professionalId"] = sessionProfessionalId
        value["lookPostId"] = lookPostId
        return try decode(ConsultLookSession.self, value: value)
    }

    func proposal(consultId: String, locationType: String,
                  enhancementLineIds: [String]) async throws -> ConsultBookingProposalAvailability {
        // The flow's own tests never reach the booking door; the proposal
        // screen is covered against the fixtures in TovisKit. A refusal here is
        // the honest stand-in — and the shape the device must survive when the
        // endpoint does not exist on the server it is pointed at.
        ConsultBookingProposalAvailability(
            available: false, reason: .estimateMissing, proposal: nil,
            professionalId: sessionProfessionalId)
    }

    func agreements(consultId: String) async throws -> ConsultAgreementState {
        try agreementState()
    }

    func acceptAgreement(consultId: String, kind: ConsultAgreementKind,
                         agreementVersionId: String) async throws -> ConsultAgreementState {
        acceptedKinds.insert(kind)
        return try agreementState()
    }

    func revokeAgreement(consultId: String, acceptanceId: String) async throws -> ConsultAgreementState {
        consentRevoked = true
        var value = try agreementDictionary()
        value["status"] = "CONSENT_REVOKED"
        var requirements = try #require(value["requirements"] as? [[String: Any]])
        for index in requirements.indices { requirements[index]["currentAcceptance"] = NSNull() }
        value["requirements"] = requirements
        return try decode(ConsultAgreementState.self, value: value)
    }

    func intake(consultId: String) async throws -> ConsultIntakeState {
        try decode(ConsultIntakeState.self, value: dictionary("intake", "intake"))
    }

    func submitIntake(consultId: String, state: ConsultIntakeState,
                      answers: [String: String], idempotencyKey: String) async throws
        -> ConsultIntakeState {
        var value = dictionary("intake", "intake")
        value["status"] = "MEDIA_READY"
        value["latestRevision"] = [
            "id": "revision_intake_1", "revision": 1, "packId": "hair-color",
            "packVersion": 1, "schemaVersion": 1, "complete": true,
            "answers": answers, "createdAt": "2026-08-11T18:05:00.000Z",
        ]
        return try decode(ConsultIntakeState.self, value: value)
    }

    func capture(consultId: String) async throws -> ConsultCaptureState {
        // 🔴 The GET must reflect what the server DECIDED, not a blank pack. The
        // flow re-reads capture state from here after every queue leg (P2d), so
        // a mock that forgot its own rejection would make a real regression —
        // a retake the client is never told about — look like passing code.
        try decode(ConsultCaptureState.self,
                   value: try captureDictionary(rejectedShot: rejectedShotKey))
    }

    /// The shot this mock has rejected and not yet seen replaced.
    private var rejectedShotKey: ConsultCaptureShotKey?

    func inspiration(consultId: String) async throws -> ConsultInspirationState {
        try inspirationState()
    }

    func skipInspiration(consultId: String, schemaVersion: Int,
                         idempotencyKey: String) async throws -> ConsultInspirationState {
        inspirationSource = "NONE"
        return try inspirationState()
    }

    func uploadInspiration(consultId: String, schemaVersion: Int, jpegData: Data,
                           keys: ConsultInspirationMutationKeys) async throws
        -> ConsultInspirationState {
        inspirationUploadByteCounts.append(jpegData.count)
        inspirationSource = "EXTERNAL_UPLOAD"
        return try inspirationState()
    }

    func answerInspiration(consultId: String, schemaVersion: Int, questionKey: String,
                           selectedValues: [String], text: String?,
                           sentiment: ConsultInspirationSentiment?,
                           idempotencyKey: String) async throws -> ConsultInspirationState {
        answeredInspirationKeys.append(questionKey)
        inspirationAnsweredCount += 1
        return try inspirationState()
    }

    /// When set, the image read throws it — the server-side half of B4 (a
    /// route that refuses, or a contract the client will not follow).
    var inspirationImageError: Error?
    private(set) var inspirationImageReads = 0

    func inspirationImage(consultId: String,
                          readEndpoint: String) async throws -> ConsultInspirationSignedRead {
        inspirationImageReads += 1
        if let inspirationImageError { throw inspirationImageError }
        return try decode(ConsultInspirationSignedRead.self, value: [
            "url": "https://storage.test/signed/inspiration.jpg?token=read",
            "expiresInSeconds": 600,
        ])
    }

    func proceedWithAccepted(consultId: String) async throws -> ConsultCaptureState {
        guard inspirationComplete, !acceptedShots.isEmpty else {
            throw ConsultClientFailure.analysisInspirationRequired
        }
        proceededWithPartialPack = true
        return try captureState()
    }

    private func inspirationState() throws -> ConsultInspirationState {
        let key: String
        if inspirationSource == nil {
            key = "inspirationSourceDecision"
        } else if inspirationSource == "NONE" {
            key = "inspirationSkipped"
        } else if inspirationAnsweredCount >= 7 {
            key = "inspirationComplete"
        } else if inspirationAnsweredCount == 6 {
            key = "inspirationTextQuestion"
        } else {
            key = "inspirationQuestion"
        }
        var value = dictionary(key, "inspiration")
        value["status"] = sessionAdvancedToAnalysis ? "ANALYSIS_PENDING" : "MEDIA_READY"
        var progress = value["progress"] as! [String: Any]
        progress["answeredQuestionCount"] = min(inspirationAnsweredCount, 7)
        value["progress"] = progress
        return try decode(ConsultInspirationState.self, value: value)
    }

    // MARK: - The three capture legs (P2d)
    //
    // The mock models what the server actually does, because the durable queue's
    // whole correctness argument rests on it: issue REPLAYS under the same key
    // (same upload session, fresh token), attach REPLAYS under its key and hands
    // back the SAME captureId, and quality is short-circuited by a verdict that
    // already exists. A mock that minted something new each time would let a
    // duplicate-spending queue pass.

    private(set) var issuedKeys: [String] = []
    private(set) var attachedKeys: [String] = []
    private(set) var qualityKeys: [String] = []
    private var uploadSessionsByIssueKey: [String: String] = [:]
    private var captureIdsByAttachKey: [String: String] = [:]
    private var verdictByCaptureId: [String: Bool] = [:]
    private var issueTokenSerial = 0
    /// Errors the next call of each leg should throw, popped in order.
    var issueErrors: [Error] = []
    var attachErrors: [Error] = []
    var qualityErrors: [Error] = []

    func issueCaptureUpload(consultId: String, shotKey: ConsultCaptureShotKey,
                            shotPackVersion: Int, schemaVersion: Int, sizeBytes: Int,
                            idempotencyKey: String) async throws -> ConsultCaptureUpload {
        issuedKeys.append(idempotencyKey)
        receivedByteCounts.append(sizeBytes)
        if !issueErrors.isEmpty { throw issueErrors.removeFirst() }
        let sessionId = uploadSessionsByIssueKey[idempotencyKey]
            ?? "upload_\(idempotencyKey.prefix(8))"
        uploadSessionsByIssueKey[idempotencyKey] = sessionId
        issueTokenSerial += 1
        let token = "token-\(issueTokenSerial)"
        return try decode(ConsultCaptureUpload.self, value: [
            "uploadSessionId": sessionId,
            "shotKey": shotKey.rawValue,
            "shotPackVersion": shotPackVersion,
            "schemaVersion": schemaVersion,
            "contentType": "image/jpeg",
            "maxBytes": sizeBytes,
            "expiresAt": "2026-08-11T19:00:00.000Z",
            "rawExpiresAt": "2026-08-12T18:00:00.000Z",
            "token": token,
            "signedUrl": "https://storage.test/storage/v1/object/upload/sign/media-private/consult-raw/v1/\(sessionId).jpg?token=\(token)",
        ])
    }

    func attachCapture(consultId: String, uploadSessionId: String,
                       shotKey: ConsultCaptureShotKey, shotPackVersion: Int,
                       schemaVersion: Int,
                       idempotencyKey: String) async throws -> ConsultCaptureAttachResponse {
        attachedKeys.append(idempotencyKey)
        if !attachErrors.isEmpty { throw attachErrors.removeFirst() }
        let captureId = captureIdsByAttachKey[idempotencyKey]
            ?? "capture_\(shotKey.rawValue)_\(attachedKeys.count)"
        captureIdsByAttachKey[idempotencyKey] = captureId
        let stateValue = try captureDictionary(rejectedShot: nil)
        return try decode(ConsultCaptureAttachResponse.self, value: [
            "capture": stateValue, "captureId": captureId, "replayed": false,
        ])
    }

    func checkCaptureQuality(consultId: String, captureId: String, shotPackVersion: Int,
                             schemaVersion: Int,
                             idempotencyKey: String) async throws -> ConsultCaptureQualityResponse {
        qualityKeys.append(idempotencyKey)
        if !qualityErrors.isEmpty { throw qualityErrors.removeFirst() }
        let shotKey = ConsultCaptureShotKey(
            captureId.replacingOccurrences(of: "capture_", with: "")
                .components(separatedBy: "_").dropLast().joined(separator: "_")
        )
        let accepted: Bool
        if let settled = verdictByCaptureId[captureId] {
            accepted = settled
        } else if shotKey == .hairBack, !rejectedBackOnce {
            rejectedBackOnce = true
            accepted = false
        } else {
            acceptedShots.insert(shotKey)
            accepted = true
        }
        rejectedShotKey = accepted ? (rejectedShotKey == shotKey ? nil : rejectedShotKey) : shotKey
        verdictByCaptureId[captureId] = accepted
        let stateValue = try captureDictionary(rejectedShot: accepted ? nil : shotKey)
        let quality: [String: Any] = [
            "captureId": captureId,
            "accepted": accepted,
            "reasonCode": accepted ? "PASS" : "WARM_INDOOR_LIGHT",
            "retakeTip": accepted ? NSNull() : "Move near a window and face the daylight.",
            "checkedAt": "2026-08-11T18:10:00.000Z",
        ]
        return try decode(ConsultCaptureQualityResponse.self, value: [
            "quality": quality,
            "capture": stateValue,
            "replayed": false,
        ])
    }

    func setChartCopy(consultId: String, optIn: Bool) async throws -> ConsultCaptureState {
        var value = try captureDictionary(rejectedShot: nil)
        value["chartCopy"] = ["optIn": optIn, "decidedAt": "2026-08-12T17:00:00.000Z"]
        return try decode(ConsultCaptureState.self, value: value)
    }

    /// P4b: a scripted sequence of run states, consumed one per `analysis`
    /// call, so a test can drive a run from QUEUED through to its outcome the
    /// way the poll would. Empty means "behave as before".
    private var scriptedRuns: [[String: Any]] = []
    private var analysisError: Error?
    private(set) var analysisReadCount = 0

    func setScriptedRunsForTest(_ runs: [[String: Any]]) { scriptedRuns = runs }

    func analysis(consultId: String) async throws -> ConsultAnalysisState {
        analysisReadCount += 1
        if let analysisError { throw analysisError }
        var value = dictionary("analysis", "analysis")
        if !scriptedRuns.isEmpty {
            let run = scriptedRuns.count > 1 ? scriptedRuns.removeFirst() : scriptedRuns[0]
            value["run"] = run
            let status = run["status"] as? String
            value["status"] = status == "COMPLETED" ? "COMPLETED" : "ANALYZING"
            return try decode(ConsultAnalysisState.self, value: value)
        }
        value["status"] = analysisStarted ? "COMPLETED" : "ANALYSIS_PENDING"
        return try decode(ConsultAnalysisState.self, value: value)
    }

    func startAnalysis(consultId: String, idempotencyKey: String) async throws
        -> ConsultAnalysisState {
        guard sessionAdvancedToAnalysis else {
            throw ConsultClientFailure.analysisInspirationRequired
        }
        analysisStarted = true
        return try await analysis(consultId: consultId)
    }

    func results(consultId: String) async throws -> ConsultClientResults {
        try decode(ConsultClientResults.self, value: dictionary("results", "results"))
    }

    func recordLockedTeaserTap(consultId: String) async throws {
        teaserRecorded = true
    }

    private func agreementState() throws -> ConsultAgreementState {
        var value = try agreementDictionary()
        value["status"] = acceptedKinds.count == 2 ? "INTAKE_READY" : "CONSENT_REQUIRED"
        var requirements = try #require(value["requirements"] as? [[String: Any]])
        for index in requirements.indices {
            let raw = requirements[index]["kind"] as? String
            let kind = raw.flatMap(ConsultAgreementKind.init(rawValue:))
            if kind.map({ !acceptedKinds.contains($0) }) ?? true {
                requirements[index]["currentAcceptance"] = NSNull()
            }
        }
        value["requirements"] = requirements
        return try decode(ConsultAgreementState.self, value: value)
    }

    private func agreementDictionary() throws -> [String: Any] {
        dictionary("agreements", "agreementState")
    }

    private func captureState(rejectedShot: ConsultCaptureShotKey? = nil) throws -> ConsultCaptureState {
        try decode(ConsultCaptureState.self, value: captureDictionary(rejectedShot: rejectedShot))
    }

    private func captureDictionary(rejectedShot: ConsultCaptureShotKey? = nil) throws -> [String: Any] {
        var value = dictionary("capture", "capture")
        value["status"] = sessionAdvancedToAnalysis ? "ANALYSIS_PENDING" : "MEDIA_READY"
        var slots = try #require(value["slots"] as? [[String: Any]])
        for index in slots.indices {
            let key = ConsultCaptureShotKey(rawValue: slots[index]["shotKey"] as? String ?? "")
            if key == rejectedShot {
                slots[index]["state"] = "REJECTED"
                slots[index]["qualityReasonCode"] = "WARM_INDOOR_LIGHT"
                slots[index]["retakeTip"] = "Move near a window and face the daylight."
                slots[index]["rawExpiresAt"] = NSNull()
                slots[index]["purgedAt"] = "2026-08-11T18:10:00.000Z"
            } else if acceptedShots.contains(key) {
                slots[index]["state"] = "ACCEPTED"
                slots[index]["qualityReasonCode"] = "PASS"
                slots[index]["retakeTip"] = NSNull()
            } else {
                slots[index]["state"] = "EMPTY"
                slots[index]["captureId"] = NSNull()
                slots[index]["qualityReasonCode"] = NSNull()
                slots[index]["retakeTip"] = NSNull()
                slots[index]["rawExpiresAt"] = NSNull()
                slots[index]["purgedAt"] = NSNull()
            }
        }
        value["slots"] = slots
        return value
    }

    private func dictionary(_ outer: String, _ inner: String) -> [String: Any] {
        ((root[outer] as! [String: Any])[inner] as! [String: Any])
    }

    private func decode<T: Decodable>(_ type: T.Type, value: Any) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }
}

private actor FirstSoftThenPassingConsultQC: ConsultPhotoQCEvaluating {
    private var first = true

    func evaluate(_ jpeg: Data, checkBlink: Bool) async -> PhotoQCReport {
        defer { first = false }
        return PhotoQCReport(
            retakeReason: first ? "It came out soft" : nil,
            sharpness: first ? 0.05 : 0.8,
            luma: 0.5,
            faceLuma: nil,
            eyesClosed: false,
            focalPoint: nil
        )
    }
}

nonisolated private struct IdentityConsultJPEGPreparation: ConsultJPEGPreparing {
    func prepare(_ source: Data) async -> Data? { source }
}

@Suite(.serialized) @MainActor struct ConsultFlowViewModelTests {
    private func fixtureRoot() throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repo.appendingPathComponent(
            "TovisKit/Tests/TovisKitTests/Fixtures/consultFlow.json"
        )
        return try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    /// A queue wired to the mock service, with the transfer completing inline so
    /// a "round trip" is deterministic. Everything else — the leg ordering, the
    /// persisted keys, the vault — is the real thing.
    private func testQueue(_ service: MockConsultService) async -> ConsultCaptureUploadQueue {
        await ConsultCaptureUploadQueueTestSupport.freshQueue(service: service)
    }

    /// Both capture tests write real bytes to the real vault, so they run inside
    /// their own isolated one — suites run in parallel and a shared vault means
    /// one suite's queue drains another's items. See
    /// `ConsultCaptureVaultIsolation`.
    private func withCaptureVault(_ name: String, _ body: () async throws -> Void) async throws {
        try await ConsultCaptureUploadQueueTestSupport.isolated(name, body)
    }

    /// Take one shot AND let the durable queue finish it. In the app these are
    /// separate — that separation is the point of P2d — so a test that wants to
    /// assert on the outcome has to wait for the queue rather than for the call.
    private func submit(
        _ model: ConsultFlowViewModel, _ jpeg: Data, for shot: ConsultCaptureShot
    ) async {
        await model.submitPhoto(jpeg, for: shot)
        await model.uploads.settle()
    }

    @Test func completeMockedGuidedBookingConsultFlowIncludesLocalAndServerRetakes() async throws {
        try await withCaptureVault("flow-full") {
            let service = MockConsultService(root: try fixtureRoot())
            let model = ConsultFlowViewModel(
                anchor: .booking("booking_fixture_1"),
                professionalId: "cmq9p645v0002jp04fttoatlq",
                service: service,
                uploads: await testQueue(service)
            )

            await model.start()
            #expect(model.stage == .prerequisites)
            let sensitive = try #require(model.agreementState?.requirements.first {
                $0.kind == .sensitiveDataConsent
            })
            await model.accept(sensitive)
            let adult = try #require(model.agreementState?.requirements.first {
                $0.kind == .adult18PlusAttestation
            })
            await model.accept(adult)
            #expect(model.stage == .intake)
            #expect(model.answers["change_scale"] == "noticeable")

            let questions = try #require(model.intakeState?.questionPack.questions)
            for question in questions where question.requirement == .required
                && model.answers[question.key] == nil {
                model.selectAnswer(
                    questionKey: question.key,
                    value: try #require(question.options.first?.value)
                )
            }
            await model.submitIntake()
            #expect(model.stage == .capture)
            #expect(model.inspirationState?.progress.blocker == .sourceDecisionRequired)
            #expect(!model.inspirationDone)

            let shots = try #require(model.captureState?.shotPack.shots)
            let back = try #require(shots.first { $0.key == .hairBack })
            let guidedPipeline = ConsultTransientPhotoPipeline(
                quality: FirstSoftThenPassingConsultQC(),
                preparation: IdentityConsultJPEGPreparation()
            )
            let localFailure = await guidedPipeline.process(
                Data("soft-back".utf8),
                expectations: ConsultShotGuidance.expectations(for: back.key)
            )
            #expect(localFailure == .retake("It came out soft"))
            #expect(await service.receivedByteCounts.isEmpty)

            let firstBack = await guidedPipeline.process(
                Data("first-back".utf8),
                expectations: ConsultShotGuidance.expectations(for: back.key)
            )
            guard case let .accepted(firstBackJPEG) = firstBack else {
                Issue.record("Guided post-capture QC should accept the retry")
                return
            }
            await submit(model, firstBackJPEG, for: back)
            #expect(model.captureState?.slots.first { $0.shotKey == .hairBack }?.state == .rejected)
            #expect(model.captureState?.slots.first { $0.shotKey == .hairBack }?.retakeTip != nil)
            let serverRetake = await guidedPipeline.process(
                Data("retake-back".utf8),
                expectations: ConsultShotGuidance.expectations(for: back.key)
            )
            guard case let .accepted(serverRetakeJPEG) = serverRetake else {
                Issue.record("Guided QC should accept the server-requested retake")
                return
            }
            await submit(model, serverRetakeJPEG, for: back)
            for shot in shots where shot.key != .hairBack {
                let outcome = await guidedPipeline.process(
                    Data("photo-\(shot.key.rawValue)".utf8),
                    expectations: ConsultShotGuidance.expectations(for: shot.key)
                )
                guard case let .accepted(jpeg) = outcome else {
                    Issue.record("Every deterministic guided shot should pass local QC")
                    return
                }
                await submit(model, jpeg, for: shot)
            }
            // 7/7 accepted but the inspiration review is still open: the server
            // holds the session at MEDIA_READY, and the client must not jump ahead
            // locally (the old hasAllAcceptedShots shortcut dead-ended exactly here).
            #expect(model.captureState?.hasAllAcceptedShots == true)
            #expect(model.stage == .capture)
            #expect(!model.canOfferPartialContinue)

            await model.uploadInspirationPhoto(Data("inspiration-look".utf8))
            var answeredRounds = 0
            while let question = model.inspirationState?.progress.currentQuestion,
                  answeredRounds < 10 {
                answeredRounds += 1
                if question.kind == .text {
                    await model.answerInspiration(
                        question: question, selectedValues: [], text: "", sentiment: nil
                    )
                } else {
                    let value = try #require(question.options.first?.value)
                    await model.answerInspiration(
                        question: question, selectedValues: [value], text: "", sentiment: nil
                    )
                }
            }
            #expect(answeredRounds == 7)
            #expect(model.inspirationDone)
            #expect(await service.inspirationUploadByteCounts == [Data("inspiration-look".utf8).count])
            #expect(await service.answeredInspirationKeys.count == 7)
            // The completed review advances the session server-side; the client
            // follows it into the analysis stage instead of deciding locally.
            #expect(model.stage == .analysis)
            #expect(model.analysisState?.status == .analysisPending)

            await model.startAnalysis()
            #expect(model.stage == .results)
            #expect(model.results?.clientIntake.first?.questionKey == "desired_color")
            #expect(model.results?.safetyFlags.first?.code == "RECENT_BOX_DYE")
            #expect(model.results?.recommendationDirections.count == 2)
            #expect(model.results?.meCardTeaser.locked == true)

            await model.tapLockedMeCard()
            #expect(model.teaserTapped)
            #expect(await service.teaserRecorded)
            #expect(await service.receivedByteCounts.count == 8)
            #expect(await guidedPipeline.retainedByteCount() == 0)
            // Eight photographs, eight DISTINCT issue keys — and no more than eight,
            // which is what says a retry replayed its key instead of minting a
            // second upload session and a second paid quality check.
            let issued = await service.issuedKeys
            #expect(Set(issued).count == 8)
            #expect(await Set(service.qualityKeys).count == 8)
            // Nothing is still owed: every shot's bytes were released on its verdict.
            #expect(model.uploads.items(consultId: "consult_fixture_1").isEmpty)
            #expect(model.failure == nil)
        }
    }

    @Test func partialPackContinuesThroughProceedOnceInspirationIsDone() async throws {
        try await withCaptureVault("flow-partial") {
            let service = MockConsultService(root: try fixtureRoot())
            let model = ConsultFlowViewModel(
                anchor: .booking("booking_fixture_1"),
                professionalId: "cmq9p645v0002jp04fttoatlq",
                service: service,
                uploads: await testQueue(service)
            )

            await model.start()
            for requirement in model.agreementState?.requirements ?? [] {
                await model.accept(requirement)
            }
            let questions = try #require(model.intakeState?.questionPack.questions)
            for question in questions where question.requirement == .required
                && model.answers[question.key] == nil {
                model.selectAnswer(
                    questionKey: question.key,
                    value: try #require(question.options.first?.value)
                )
            }
            await model.submitIntake()
            #expect(model.stage == .capture)

            // Continuing without an inspiration photo is a complete review.
            await model.skipInspiration()
            #expect(model.inspirationDone)
            #expect(model.stage == .capture)

            // One accepted photo out of seven unlocks the partial-pack path.
            let left = try #require(model.captureState?.shotPack.shots.first { $0.key == .hairLeft })
            await submit(model, Data("left".utf8), for: left)
            #expect(model.acceptedShotCount == 1)
            #expect(model.stage == .capture)
            #expect(model.canOfferPartialContinue)

            await model.proceedWithAccepted()
            #expect(model.stage == .analysis)
            #expect(model.analysisState?.status == .analysisPending)

            await model.startAnalysis()
            #expect(model.stage == .results)
            #expect(model.failure == nil)
        }
    }

    /// P4b: the analysis became a background run, so the screen has to follow
    /// it rather than block on one request.
    @Test func aLiveRunIsPolledUntilItSettles() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        await service.setScriptedRunsForTest([
            runJSON(status: "RUNNING", stage: "READING_PHOTOS"),
            runJSON(status: "RUNNING", stage: "BUILDING_PLAN"),
            runJSON(status: "COMPLETED", stage: "DONE"),
        ])
        let model = ConsultFlowViewModel(
            anchor: .booking("booking_fixture_1"),
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service
        )
        await model.start()

        // Reading the analysis directly is enough — the poll starts from the
        // load, not from a particular route through the wizard.
        await model.refreshAnalysis()
        #expect(model.analysisState?.run?.stage == .readingPhotos)

        // The poll ticks every 5s; drive it by hand instead of sleeping 15
        // seconds in a unit test.
        await model.pollOnceForTest()
        #expect(model.analysisState?.run?.stage == .buildingPlan)
        await model.pollOnceForTest()
        #expect(model.analysisState?.run?.status == .completed)
        #expect(model.stage == .results)
        #expect(model.failure == nil)
    }

    /// A dropped poll is not a failed analysis. The run is still going on the
    /// server; showing an error here would tell her something is wrong when
    /// nothing is.
    @Test func aDroppedPollDoesNotSurfaceAsAFailure() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        await service.setScriptedRunsForTest([
            runJSON(status: "RUNNING", stage: "BUILDING_PLAN"),
        ])
        let model = ConsultFlowViewModel(
            anchor: .booking("booking_fixture_1"),
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service
        )
        await model.start()
        await model.refreshAnalysis()

        await service.setAnalysisErrorForTest(URLError(.timedOut))
        await model.pollOnceForTest()
        #expect(model.failure == nil)
        #expect(model.busy == false)
        // The last good state is still on screen rather than being cleared.
        #expect(model.analysisState?.run?.stage == .buildingPlan)
    }

    /// A FAILED run is the one state that gives the client something to press.
    @Test func aFailedRunOffersTheRetryAndStopsPolling() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        await service.setScriptedRunsForTest([
            runJSON(
                status: "FAILED",
                stage: "BUILDING_PLAN",
                retryable: true,
                failureCode: "ANALYSIS_UNAVAILABLE"
            ),
        ])
        let model = ConsultFlowViewModel(
            anchor: .booking("booking_fixture_1"),
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service
        )
        await model.start()
        await model.refreshAnalysis()

        let run = try #require(model.analysisState?.run)
        #expect(run.status == .failed)
        #expect(run.retryable)
        #expect(!run.status.isLive)
        // The copy layer turns that into a retry, and says nothing about why.
        let progress = ConsultAnalysisRunCopy.progress(for: run)
        #expect(progress.headline == "We couldn’t finish your plan.")
        #expect(!progress.headline.contains("ANALYSIS_UNAVAILABLE"))
    }

    private func runJSON(
        status: String,
        stage: String,
        retryable: Bool = false,
        failureCode: String? = nil
    ) -> [String: Any] {
        [
            "runId": "run_fixture_1",
            "status": status,
            "stage": stage,
            "photoCount": 4,
            "attemptCount": 1,
            "maxAttempts": 3,
            "queuedAt": "2026-09-04T10:00:00.000Z",
            "startedAt": "2026-09-04T10:00:01.000Z",
            "finishedAt": NSNull(),
            "failureCode": failureCode ?? NSNull(),
            "retryable": retryable,
        ]
    }

    /// The gate lives server-side now: a pro the pilot is dark for gets a 404
    /// from every consult route, and the device renders that as hidden — no
    /// local copy of the exposure rule exists to disagree with the server.
    @Test func serverHiddenAnswerKeepsTheConsultDark() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        await service.setCreateErrorForTest(
            APIError.server(status: 404, message: "Not found.", code: nil)
        )
        let model = ConsultFlowViewModel(
            anchor: .booking("booking_fixture_1"),
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service
        )
        await model.start()
        #expect(model.stage == .prerequisites)
        #expect(model.failure == .hidden)
        #expect(model.machine.consultId == nil)
    }

    @Test func revokingSensitiveConsentStopsTheFlow() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        let model = ConsultFlowViewModel(
            anchor: .booking("booking_fixture_1"),
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service
        )

        await model.start()
        let sensitive = try #require(model.agreementState?.requirements.first {
            $0.kind == .sensitiveDataConsent
        })
        await model.accept(sensitive)
        await model.revokeSensitiveConsent()

        #expect(model.stage == .stopped)
        #expect(await service.consentRevoked)
        #expect(model.failure == nil)
    }

    @Test func serverProfessionalMustMatchTheFounderGatedBooking() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        await service.setSessionProfessionalIdForTest("professional_other")
        let model = ConsultFlowViewModel(
            anchor: .booking("booking_fixture_1"),
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service
        )

        await model.start()
        #expect(model.failure == .hidden)
        #expect(model.machine.consultId == nil)
    }

    /// Drives a model as far as an ATTACHED inspiration source, which is the
    /// only state in which the image panel renders.
    private func modelAtInspiration(
        _ service: MockConsultService
    ) async throws -> ConsultFlowViewModel {
        let model = ConsultFlowViewModel(
            anchor: .booking("booking_fixture_1"),
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service
        )
        await model.start()
        for kind in [ConsultAgreementKind.sensitiveDataConsent, .adult18PlusAttestation] {
            let requirement = try #require(model.agreementState?.requirements.first {
                $0.kind == kind
            })
            await model.accept(requirement)
        }
        let questions = try #require(model.intakeState?.questionPack.questions)
        for question in questions where question.requirement == .required
            && model.answers[question.key] == nil {
            model.selectAnswer(
                questionKey: question.key,
                value: try #require(question.options.first?.value)
            )
        }
        await model.submitIntake()
        await model.uploadInspirationPhoto(Data("inspiration".utf8))
        #expect(model.inspirationState?.source?.imageAvailable == true)
        return model
    }

    /// 🔴 B4. A failed image read is a SURFACED failure, not "no image":
    /// `.failed` is what puts "we couldn't load your inspiration photo" and a
    /// Retry in front of the client. It used to be swallowed into `nil`, which
    /// the panel could not tell apart from having nothing to show.
    @Test func aFailedInspirationImageReadIsSurfacedNotSwallowed() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        let model = try await modelAtInspiration(service)
        #expect(await model.inspirationImage() == .ready(
            try #require(URL(string: "https://storage.test/signed/inspiration.jpg?token=read"))
        ))

        let refusing = MockConsultService(root: try fixtureRoot())
        await refusing.setInspirationImageErrorForTest(ConsultClientFailure.contractMismatch)
        let refused = try await modelAtInspiration(refusing)
        #expect(await refused.inspirationImage() == .failed)
        // One read per call — a failure schedules no retry of its own.
        #expect(await refusing.inspirationImageReads == 1)
        #expect(await refused.inspirationImage() == .failed)
        #expect(await refusing.inspirationImageReads == 2)
    }

    /// No source attached → nothing to show, and nothing to report. The panel
    /// does not render at all in this state.
    @Test func anAbsentInspirationSourceIsUnavailableNotFailed() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        let model = ConsultFlowViewModel(
            anchor: .booking("booking_fixture_1"),
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service
        )
        await model.start()
        #expect(await model.inspirationImage() == .unavailable)
        #expect(await service.inspirationImageReads == 0)
    }

    // ── P6: one question at a time, and what the diet actually cost ────────

    /// Every question a pack asks, as the wire shape, so a pack version can be
    /// stood up in a fixture and DRIVEN rather than described.
    private func packQuestion(
        _ key: String, _ requirement: String, _ option: String
    ) -> [String: Any] {
        [
            "key": key, "label": "\(key)?", "helpText": NSNull(),
            "kind": "SINGLE_SELECT", "requirement": requirement,
            "options": [["value": option, "label": option]],
        ]
    }

    /// The colour pack as it shipped BEFORE the diet (v2, 15 questions), so
    /// the tap count is measured against the real thing rather than recalled.
    private func hairColorV2Questions() -> [[String: Any]] {
        [
            packQuestion("current_color", "REQUIRED", "brunette"),
            packQuestion("desired_color", "REQUIRED", "red"),
            packQuestion("change_scale", "REQUIRED", "noticeable"),
            packQuestion("goal_direction", "CONDITIONAL", "lighter"),
            packQuestion("box_dye_history", "REQUIRED", "never"),
            packQuestion("prior_lightening", "REQUIRED", "never"),
            packQuestion("henna_plant_dye_history", "REQUIRED", "never"),
            packQuestion("perm_history", "REQUIRED", "never"),
            packQuestion("relaxer_texturizer_history", "REQUIRED", "never"),
            packQuestion("keratin_smoothing_history", "REQUIRED", "never"),
            packQuestion("other_chemical_history", "REQUIRED", "never"),
            packQuestion("last_color_service_timing", "REQUIRED", "1-3-months"),
            packQuestion("prior_reaction", "REQUIRED", "no"),
            packQuestion("event_timing", "SKIPPABLE", "no-deadline"),
            packQuestion("budget", "SKIPPABLE", "150-250"),
        ]
    }

    /// Drives the intake by tapping ONLY the question the screen is currently
    /// offering, and returns how many taps it took to reach the photo step —
    /// including the final Continue. Fails if the screen ever offers a
    /// question that is not the pack's first unanswered one, which is what
    /// "one question at a time" has to mean.
    private func tapsToThePhotoStep(
        questions: [[String: Any]], nextQuestionKey: String
    ) async throws -> Int {
        var root = try fixtureRoot()
        var intakeEnvelope = try #require(root["intake"] as? [String: Any])
        var intake = try #require(intakeEnvelope["intake"] as? [String: Any])
        var pack = try #require(intake["questionPack"] as? [String: Any])
        pack["questions"] = questions
        intake["questionPack"] = pack
        intake["progress"] = [
            "canComplete": false, "nextQuestionKey": nextQuestionKey,
            "blocker": "REQUIRED_ANSWERS_MISSING",
        ]
        // Measured with no prefill on either side, so the comparison is the
        // PACK's cost and not a prefill discount that differs between them.
        intake["prefillSuggestions"] = [[String: Any]]()
        intakeEnvelope["intake"] = intake
        root["intake"] = intakeEnvelope

        let service = MockConsultService(root: root)
        let model = ConsultFlowViewModel(
            anchor: .booking("booking_fixture_1"),
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service
        )
        await model.start()
        await model.accept(try #require(model.agreementState?.requirements.first {
            $0.kind == .sensitiveDataConsent
        }))
        await model.accept(try #require(model.agreementState?.requirements.first {
            $0.kind == .adult18PlusAttestation
        }))
        #expect(model.stage == .intake)

        let keys = questions.compactMap { $0["key"] as? String }
        let required = Set(
            questions
                .filter { $0["requirement"] as? String == "REQUIRED" }
                .compactMap { $0["key"] as? String }
        )
        var taps = 0
        while let question = model.intakeQuestion {
            // The server's own order: every REQUIRED question first, then
            // whatever is left (the conditional goal direction, and anything
            // skippable) — which is exactly what the web wizard walks.
            let expected =
                keys.first { required.contains($0) && model.answers[$0] == nil }
                ?? keys.first { model.answers[$0] == nil }
            #expect(
                question.key == expected,
                "tap \(taps): got \(question.key), expected \(expected ?? "nil")"
            )
            #expect(model.intakeAnsweredCount == taps)
            model.selectAnswer(
                questionKey: question.key,
                value: try #require(question.options.first?.value)
            )
            taps += 1
            #expect(taps <= keys.count)
        }
        #expect(model.intakeAnsweredCount == keys.count)
        #expect(model.canSubmitIntake)
        await model.submitIntake()
        #expect(model.stage == .capture)
        return taps + 1
    }

    /// The product principle, measured: the consult must feel like an impulse,
    /// not a form. Sixteen taps to reach the camera was a form.
    @Test func theIntakeDietCutsTheTapsToThePhotoStep() async throws {
        let before = try await tapsToThePhotoStep(
            questions: hairColorV2Questions(), nextQuestionKey: "current_color"
        )
        #expect(before == 16)

        // The SHIPPED pack, read out of the same fixture the contract tests
        // validate — not a copy of it.
        let root = try fixtureRoot()
        let envelope = try #require(root["intake"] as? [String: Any])
        let shippedIntake = try #require(envelope["intake"] as? [String: Any])
        let shipped = try #require(shippedIntake["questionPack"] as? [String: Any])
        let shippedQuestions = try #require(shipped["questions"] as? [[String: Any]])
        #expect(shippedQuestions.count == 7)
        let after = try await tapsToThePhotoStep(
            questions: shippedQuestions, nextQuestionKey: "change_scale"
        )
        #expect(after == 8)
    }

    /// The header names the service — the thing the look-based flow never did
    /// (handoff B6). With no service resolvable it must not render a hole.
    @Test func theIntakeHeaderNamesTheService() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        let model = ConsultFlowViewModel(
            anchor: .booking("booking_fixture_1"),
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service
        )
        await model.start()
        await model.accept(try #require(model.agreementState?.requirements.first {
            $0.kind == .sensitiveDataConsent
        }))
        await model.accept(try #require(model.agreementState?.requirements.first {
            $0.kind == .adult18PlusAttestation
        }))
        // The CLIENT-facing name (the pro's offering title), not the catalog one.
        #expect(model.intakeServiceName == "Signature Balayage")

        var root = try fixtureRoot()
        var envelope = try #require(root["intake"] as? [String: Any])
        var intake = try #require(envelope["intake"] as? [String: Any])
        intake["service"] = [
            "serviceId": NSNull(), "name": NSNull(), "proFacingName": NSNull(),
        ]
        envelope["intake"] = intake
        root["intake"] = envelope
        let unnamedService = MockConsultService(root: root)
        let unnamed = ConsultFlowViewModel(
            anchor: .booking("booking_fixture_1"),
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: unnamedService
        )
        await unnamed.start()
        await unnamed.accept(try #require(unnamed.agreementState?.requirements.first {
            $0.kind == .sensitiveDataConsent
        }))
        await unnamed.accept(try #require(unnamed.agreementState?.requirements.first {
            $0.kind == .adult18PlusAttestation
        }))
        #expect(unnamed.intakeServiceName == nil)
    }
}

private extension MockConsultService {
    func setSessionProfessionalIdForTest(_ value: String) {
        sessionProfessionalId = value
    }

    func setCreateErrorForTest(_ error: Error) {
        createError = error
    }

    func setAnalysisErrorForTest(_ error: Error?) {
        analysisError = error
    }

    func setInspirationImageErrorForTest(_ error: Error?) {
        inspirationImageError = error
    }
}
