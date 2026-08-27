import Foundation
import Testing
@testable import TovisKit

@Suite struct ConsultContractTests {
    private func root() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: fixture("consultFlow")) as? [String: Any])
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        let value = try #require(try root()[key])
        return try decode(type, value: value)
    }

    private func decode<T: Decodable>(_ type: T.Type, value: Any) throws -> T {
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @Test func decodesEveryC1ThroughC7ClientContract() throws {
        let session = try decode(ConsultSessionResponse.self, key: "session").consult
        #expect(session.status == .consentRequired)
        #expect(session.bookingId == "booking_fixture_1")

        let agreements = try decode(ConsultAgreementStateResponse.self, key: "agreements").agreementState
        #expect(agreements.allCurrent)
        #expect(agreements.requirements.map(\.kind) == [
            .sensitiveDataConsent, .adult18PlusAttestation,
        ])

        let intake = try decode(ConsultIntakeStateResponse.self, key: "intake").intake
        #expect(intake.questionPack.id == "hair-color")
        #expect(intake.questionPack.questions.count == 9)
        #expect(intake.questionPack.questions.first { $0.key == "box_dye_history" } != nil)

        let capture = try decode(ConsultCaptureStateResponse.self, key: "capture").capture
        #expect(capture.shotPack.shots.map(\.key) == ConsultCaptureShotKey.allCases)
        #expect(capture.hasAllAcceptedShots)

        let analysis = try decode(ConsultAnalysisStartResponse.self, key: "analysis").analysis
        #expect(analysis.status == .completed)
        #expect(analysis.schemaVersion == 1)
        #expect(analysis.promptVersion == "hair-color-analysis-v1")

        let results = try decode(ConsultClientResultsResponse.self, key: "results").results
        #expect(results.hasFaithfulClientContract)
        #expect(results.recommendationDirections.count == 2)
        #expect(results.safetyFlags.count == 1)
        #expect(results.meCardTeaser.locked)

        let teaser = try decode(ConsultTeaserTapResponse.self, key: "teaser")
        #expect(teaser.teaser.locked)
        #expect(teaser.teaser.tapped)
    }

    @Test func rejectedPhotoCarriesExactlyOneRetakeTipAndNoLiveRawPointer() throws {
        let state = try decode(ConsultCaptureState.self, key: "captureRejected")
        let rejected = try #require(state.slots.first { $0.state == .rejected })
        #expect(rejected.qualityReasonCode == "WARM_INDOOR_LIGHT")
        #expect(rejected.retakeTip == "Move near a window and face the daylight.")
        #expect(rejected.rawExpiresAt == nil)
        #expect(rejected.purgedAt != nil)
    }

    @Test func resultOrderKeepsClientWordsBeforeAIAndSafetySeparate() {
        #expect(ConsultResultPresentation.sections == [
            .clientWords, .aiObservations, .safety, .achievability,
            .directions, .lockedMeCard,
        ])
        #expect(ConsultResultPresentation.sections.firstIndex(of: .clientWords)! <
                ConsultResultPresentation.sections.firstIndex(of: .aiObservations)!)
        #expect(ConsultResultPresentation.sections.contains(.safety))
    }

    @Test func stateMachinePinsBookingConsultAndImmutableRevisionProvenance() throws {
        let session = try decode(ConsultSessionResponse.self, key: "session").consult
        let agreements = try decode(ConsultAgreementStateResponse.self, key: "agreements").agreementState
        let intake = try decode(ConsultIntakeStateResponse.self, key: "intake").intake
        let capture = try decode(ConsultCaptureStateResponse.self, key: "capture").capture
        let analysis = try decode(ConsultAnalysisStartResponse.self, key: "analysis").analysis
        let results = try decode(ConsultClientResultsResponse.self, key: "results").results

        var machine = ConsultFlowMachine(bookingId: "booking_fixture_1")
        try machine.apply(session: session)
        #expect(machine.stage == .prerequisites)
        try machine.apply(agreements: agreements)
        #expect(machine.stage == .intake)
        try machine.apply(intake: intake)
        #expect(machine.stage == .intake)
        try machine.apply(capture: capture)
        #expect(machine.stage == .analysis)
        try machine.apply(analysis: analysis)
        #expect(machine.stage == .results)
        try machine.apply(results: results)
        #expect(machine.stage == .results)
        #expect(machine.consultId == "consult_fixture_1")

        var wrongBooking = ConsultFlowMachine(bookingId: "other_booking")
        #expect(throws: ConsultClientFailure.contractMismatch) {
            try wrongBooking.apply(session: session)
        }
    }

    @Test func resumedCompletedAgreementStateDoesNotFallBackToIntake() throws {
        let session = try decode(ConsultSessionResponse.self, key: "session").consult
        var agreementEnvelope = try #require(try root()["agreements"] as? [String: Any])
        var agreementState = try #require(agreementEnvelope["agreementState"] as? [String: Any])
        agreementState["status"] = "COMPLETED"
        agreementEnvelope["agreementState"] = agreementState
        let agreements = try decode(
            ConsultAgreementStateResponse.self,
            value: agreementEnvelope
        ).agreementState

        var machine = ConsultFlowMachine(bookingId: session.bookingId)
        try machine.apply(session: session)
        try machine.apply(agreements: agreements)
        #expect(machine.stage == .results)
    }

    @Test func resultRevisionMustMatchObservedIntakeAndAnalysisRevisions() throws {
        let session = try decode(ConsultSessionResponse.self, key: "session").consult

        var intakeEnvelope = try #require(try root()["intake"] as? [String: Any])
        var intakeValue = try #require(intakeEnvelope["intake"] as? [String: Any])
        intakeValue["latestRevision"] = [
            "id": "revision_intake_1", "revision": 1, "packId": "hair-color",
            "packVersion": 1, "schemaVersion": 1, "complete": true,
            "answers": ["desired_color": "copper"],
            "createdAt": "2026-08-11T18:05:00.000Z",
        ]
        intakeEnvelope["intake"] = intakeValue
        let intake = try decode(ConsultIntakeStateResponse.self, value: intakeEnvelope).intake

        var analysisEnvelope = try #require(try root()["analysis"] as? [String: Any])
        var analysisValue = try #require(analysisEnvelope["analysis"] as? [String: Any])
        analysisValue["result"] = [
            "revisionId": "revision_analysis_2", "revision": 2,
            "analysis": [:], "createdAt": "2026-08-11T18:19:00.000Z",
        ]
        analysisEnvelope["analysis"] = analysisValue
        let analysis = try decode(ConsultAnalysisStartResponse.self, value: analysisEnvelope).analysis

        var resultsEnvelope = try #require(try root()["results"] as? [String: Any])
        var resultsValue = try #require(resultsEnvelope["results"] as? [String: Any])
        resultsValue["analysisRevisionId"] = "revision_analysis_other"
        resultsEnvelope["results"] = resultsValue
        let mismatched = try decode(ConsultClientResultsResponse.self, value: resultsEnvelope).results

        var machine = ConsultFlowMachine(bookingId: session.bookingId)
        try machine.apply(session: session)
        try machine.apply(intake: intake)
        try machine.apply(analysis: analysis)
        #expect(throws: ConsultClientFailure.contractMismatch) {
            try machine.apply(results: mismatched)
        }
    }

    @Test func productionGateStaysDarkEvenForFounderWithoutBothLiveEvidenceChecks() {
        #expect(ConsultExposurePolicy.c5LiveBaselineApproved == false)
        #expect(ConsultExposurePolicy.c5LiveCandidatePassed == false)
        #expect(!ConsultExposurePolicy.production.allows(
            professionalId: "cmq9p645v0002jp04fttoatlq"
        ))
        let onlyOne = ConsultExposurePolicy(
            founderProfessionalIDs: ["founder"],
            liveBaselineApproved: true,
            liveCandidatePassed: false
        )
        #expect(!onlyOne.allows(professionalId: "founder"))
        let deterministicMock = ConsultExposurePolicy(
            founderProfessionalIDs: ["founder"],
            liveBaselineApproved: true,
            liveCandidatePassed: true
        )
        #expect(deterministicMock.allows(professionalId: "founder"))
        #expect(!deterministicMock.allows(professionalId: "someone_else"))
    }

    @Test func errorsAreStableAndContentFree() {
        let privateContent = "copper goal / consult-raw/v1/private.jpg"
        let mapped = ConsultClientFailure.stable(APIError.server(
            status: 503,
            message: privateContent,
            code: "CONSULT_ANALYSIS_UNAVAILABLE"
        ))
        #expect(mapped == .unavailable)
        #expect(!mapped.message.contains(privateContent))
        #expect(!mapped.message.contains("copper"))
        #expect(!mapped.message.contains("consult-raw"))
    }

    @Test func fixtureCarriesNoRawBytesPathsOrForbiddenTraits() throws {
        // Decision 2026-08-26 (full-analysis launch): cosmetic feature
        // observations (undertone, face/eye descriptors) are now first-class
        // wire content, so they left this list. Raw image material and
        // identity/medical traits remain forbidden.
        let text = try #require(String(data: fixture("consultFlow"), encoding: .utf8))
        for forbidden in [
            "base64", "storagePath", "storageBucket", "ethnicity", "diagnosis",
        ] {
            #expect(!text.contains("\"\(forbidden)\""))
        }
    }
}
