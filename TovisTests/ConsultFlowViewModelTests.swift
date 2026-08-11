import Foundation
import Testing
import TovisKit
@testable import Tovis

private actor MockConsultService: ConsultServicing {
    private let root: [String: Any]
    private var acceptedKinds: Set<ConsultAgreementKind> = []
    private var acceptedShots: Set<ConsultCaptureShotKey> = []
    private var rejectedBackOnce = false
    private(set) var captureKeys: [ConsultCaptureMutationKeys] = []
    private(set) var receivedByteCounts: [Int] = []
    private(set) var teaserRecorded = false
    private(set) var consentRevoked = false
    var sessionProfessionalId = "cmq9p645v0002jp04fttoatlq"

    init(root: [String: Any]) { self.root = root }

    func create(bookingId: String) async throws -> ConsultSession {
        var value = dictionary("session", "consult")
        value["professionalId"] = sessionProfessionalId
        return try decode(ConsultSession.self, value: value)
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

    func analysis(consultId: String) async throws -> ConsultAnalysisState {
        try decode(ConsultAnalysisState.self, value: dictionary("analysis", "analysis"))
    }

    func startAnalysis(consultId: String, idempotencyKey: String) async throws
        -> ConsultAnalysisState {
        try await analysis(consultId: consultId)
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
        value["status"] = acceptedShots.count == ConsultCaptureShotKey.allCases.count
            ? "ANALYSIS_PENDING" : "MEDIA_READY"
        var slots = try #require(value["slots"] as? [[String: Any]])
        for index in slots.indices {
            let key = ConsultCaptureShotKey(rawValue: slots[index]["shotKey"] as? String ?? "")
            if key == rejectedShot {
                slots[index]["state"] = "REJECTED"
                slots[index]["qualityReasonCode"] = "WARM_INDOOR_LIGHT"
                slots[index]["retakeTip"] = "Move near a window and face the daylight."
                slots[index]["rawExpiresAt"] = NSNull()
                slots[index]["purgedAt"] = "2026-08-11T18:10:00.000Z"
            } else if let key, acceptedShots.contains(key) {
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

    @Test func completeMockedBookingConsultResultsFlowIncludesRetakeAndLockedTeaser() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        let openMockGate = ConsultExposurePolicy(
            founderProfessionalIDs: ["cmq9p645v0002jp04fttoatlq"],
            liveBaselineApproved: true,
            liveCandidatePassed: true
        )
        let model = ConsultFlowViewModel(
            bookingId: "booking_fixture_1",
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service,
            exposure: openMockGate
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

        let shots = try #require(model.captureState?.shotPack.shots)
        let back = try #require(shots.first { $0.key == .hairBack })
        await model.submitPhoto(Data("first-back".utf8), for: back)
        #expect(model.captureState?.slots.first { $0.shotKey == .hairBack }?.state == .rejected)
        #expect(model.captureState?.slots.first { $0.shotKey == .hairBack }?.retakeTip != nil)
        await model.submitPhoto(Data("retake-back".utf8), for: back)
        for shot in shots where shot.key != .hairBack {
            await model.submitPhoto(Data("photo-\(shot.key.rawValue)".utf8), for: shot)
        }
        #expect(model.stage == .analysis)

        await model.startAnalysis()
        #expect(model.stage == .results)
        #expect(model.results?.clientIntake.first?.questionKey == "desired_color")
        #expect(model.results?.safetyFlags.first?.code == "RECENT_BOX_DYE")
        #expect(model.results?.recommendationDirections.count == 2)
        #expect(model.results?.meCardTeaser.locked == true)

        await model.tapLockedMeCard()
        #expect(model.teaserTapped)
        #expect(await service.teaserRecorded)
        #expect(await service.receivedByteCounts.count == 5)
        let keys = await service.captureKeys
        #expect(Set(keys.map(\.issue)).count == 5)
        #expect(model.failure == nil)
    }

    @Test func productionGatePreventsEvenCreatingTheConsultShell() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        let model = ConsultFlowViewModel(
            bookingId: "booking_fixture_1",
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
        let openMockGate = ConsultExposurePolicy(
            founderProfessionalIDs: ["cmq9p645v0002jp04fttoatlq"],
            liveBaselineApproved: true,
            liveCandidatePassed: true
        )
        let model = ConsultFlowViewModel(
            bookingId: "booking_fixture_1",
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service,
            exposure: openMockGate
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
        let openMockGate = ConsultExposurePolicy(
            founderProfessionalIDs: ["cmq9p645v0002jp04fttoatlq"],
            liveBaselineApproved: true,
            liveCandidatePassed: true
        )
        let model = ConsultFlowViewModel(
            bookingId: "booking_fixture_1",
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service,
            exposure: openMockGate
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
}
