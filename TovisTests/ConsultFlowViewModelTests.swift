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
        try captureState()
    }

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

    func inspirationImage(consultId: String,
                          readEndpoint: String) async throws -> ConsultInspirationSignedRead {
        try decode(ConsultInspirationSignedRead.self, value: [
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

    func uploadAndCheckCapture(consultId: String, shot: ConsultCaptureShot,
                               pack: ConsultCaptureShotPack, jpegData: Data,
                               keys: ConsultCaptureMutationKeys) async throws
        -> ConsultCaptureQualityResponse {
        captureKeys.append(keys)
        receivedByteCounts.append(jpegData.count)
        let accepted: Bool
        if shot.key == .hairBack, !rejectedBackOnce {
            rejectedBackOnce = true
            accepted = false
        } else {
            acceptedShots.insert(shot.key)
            accepted = true
        }
        let stateValue = try captureDictionary(rejectedShot: accepted ? nil : shot.key)
        let quality: [String: Any] = [
            "captureId": "capture_\(shot.key.rawValue)",
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

    func analysis(consultId: String) async throws -> ConsultAnalysisState {
        var value = dictionary("analysis", "analysis")
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

    @Test func completeMockedGuidedBookingConsultFlowIncludesLocalAndServerRetakes() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        let model = ConsultFlowViewModel(
            anchor: .booking("booking_fixture_1"),
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service
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
        #expect(model.answers["desired_color"] == "copper")

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
        await model.submitPhoto(firstBackJPEG, for: back)
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
        await model.submitPhoto(serverRetakeJPEG, for: back)
        for shot in shots where shot.key != .hairBack {
            let outcome = await guidedPipeline.process(
                Data("photo-\(shot.key.rawValue)".utf8),
                expectations: ConsultShotGuidance.expectations(for: shot.key)
            )
            guard case let .accepted(jpeg) = outcome else {
                Issue.record("Every deterministic guided shot should pass local QC")
                return
            }
            await model.submitPhoto(jpeg, for: shot)
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
        let keys = await service.captureKeys
        #expect(Set(keys.map(\.issue)).count == 8)
        #expect(model.failure == nil)
    }

    @Test func partialPackContinuesThroughProceedOnceInspirationIsDone() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        let model = ConsultFlowViewModel(
            anchor: .booking("booking_fixture_1"),
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service
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
        await model.submitPhoto(Data("left".utf8), for: left)
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
}

private extension MockConsultService {
    func setSessionProfessionalIdForTest(_ value: String) {
        sessionProfessionalId = value
    }

    func setCreateErrorForTest(_ error: Error) {
        createError = error
    }
}
