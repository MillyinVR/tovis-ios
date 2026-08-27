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
        #expect(analysis.schemaVersion == 2)
        #expect(analysis.promptVersion == "full-analysis-v2")

        let results = try decode(ConsultClientResultsResponse.self, key: "results").results
        #expect(results.hasFaithfulClientContract)
        #expect(results.recommendationDirections.count == 2)
        #expect(results.styleDirections.count == 7)
        #expect(results.profile.eyeShape.value == "HOODED")
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
            .clientWords, .aiObservations, .featureProfile, .styleDirections,
            .safety, .achievability, .directions, .lockedMeCard,
        ])
        #expect(ConsultResultPresentation.sections.firstIndex(of: .clientWords)! <
                ConsultResultPresentation.sections.firstIndex(of: .aiObservations)!)
        #expect(ConsultResultPresentation.sections.firstIndex(of: .featureProfile)! <
                ConsultResultPresentation.sections.firstIndex(of: .safety)!)
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

    @Test func decodesEveryInspirationStageState() throws {
        let deciding = try decode(
            ConsultInspirationStateResponse.self, key: "inspirationSourceDecision"
        ).inspiration
        #expect(deciding.progress.blocker == .sourceDecisionRequired)
        #expect(deciding.source == nil)
        #expect(!deciding.isComplete)
        #expect(deciding.schemaVersion == 1)

        let questioning = try decode(
            ConsultInspirationStateResponse.self, key: "inspirationQuestion"
        ).inspiration
        let question = try #require(questioning.progress.currentQuestion)
        #expect(question.key == "favorite_colors")
        #expect(question.kind == .multiSelect)
        #expect(question.maxSelections == 4)
        #expect(!question.allowText)
        let source = try #require(questioning.source)
        #expect(source.source == "EXTERNAL_UPLOAD")
        #expect(source.imageAvailable)
        #expect(source.imageReadEndpoint
            == "/api/v1/client/consult/consult_fixture_1/inspiration/media")
        #expect(!questioning.isComplete)

        let texting = try decode(
            ConsultInspirationStateResponse.self, key: "inspirationTextQuestion"
        ).inspiration
        let textQuestion = try #require(texting.progress.currentQuestion)
        #expect(textQuestion.kind == .text)
        #expect(textQuestion.allowText)
        #expect(textQuestion.options.map(\.value) == ["nothing-else"])

        let complete = try decode(
            ConsultInspirationMutationResponse.self, key: "inspirationComplete"
        ).inspiration
        #expect(complete.isComplete)
        #expect(complete.status == .analysisPending)

        let skipped = try decode(
            ConsultInspirationMutationResponse.self, key: "inspirationSkipped"
        ).inspiration
        #expect(skipped.isComplete)
        #expect(skipped.source == nil)
        #expect(skipped.status == .mediaReady)
    }

    @Test func acceptedShotsAloneNeverAdvanceTheStageLocally() throws {
        // Regression: the machine once jumped capture → analysis at
        // hasAllAcceptedShots, dead-ending a 7/7 pack whose inspiration review
        // was still open. Only the server status moves the stage now.
        let session = try decode(ConsultSessionResponse.self, key: "session").consult
        var captureEnvelope = try #require(try root()["capture"] as? [String: Any])
        var captureValue = try #require(captureEnvelope["capture"] as? [String: Any])
        captureValue["status"] = "MEDIA_READY"
        captureEnvelope["capture"] = captureValue
        let allAcceptedStillMediaReady = try decode(
            ConsultCaptureStateResponse.self, value: captureEnvelope
        ).capture
        #expect(allAcceptedStillMediaReady.hasAllAcceptedShots)

        var machine = ConsultFlowMachine(bookingId: session.bookingId)
        try machine.apply(session: session)
        try machine.apply(capture: allAcceptedStillMediaReady)
        #expect(machine.stage == .capture)

        let inspiration = try decode(
            ConsultInspirationMutationResponse.self, key: "inspirationComplete"
        ).inspiration
        try machine.apply(inspiration: inspiration)
        #expect(machine.stage == .analysis)
    }

    @Test func partialPackProceedStateAdvancesViaServerStatus() throws {
        let session = try decode(ConsultSessionResponse.self, key: "session").consult
        let proceeded = try decode(
            ConsultCaptureStateResponse.self, key: "captureProceed"
        ).capture
        #expect(!proceeded.hasAllAcceptedShots)
        #expect(proceeded.slots.filter { $0.state == .accepted }.count == 2)

        var machine = ConsultFlowMachine(bookingId: session.bookingId)
        try machine.apply(session: session)
        try machine.apply(capture: proceeded)
        #expect(machine.stage == .analysis)
    }

    @Test func inspirationAnsweringMirrorsServerSelectionRules() throws {
        let questioning = try decode(
            ConsultInspirationStateResponse.self, key: "inspirationQuestion"
        ).inspiration
        let question = try #require(questioning.progress.currentQuestion)

        // A neutral choice replaces everything; a real choice clears neutrals.
        var selection = ConsultInspirationAnswering.toggle(
            "lightest-pieces", in: [], question: question
        )
        selection = ConsultInspirationAnswering.toggle(
            "not-sure", in: selection, question: question
        )
        #expect(selection == ["not-sure"])
        selection = ConsultInspirationAnswering.toggle(
            "copper-red", in: selection, question: question
        )
        #expect(selection == ["copper-red"])

        // The max-selection cap holds; tapping a selected value removes it.
        selection = ["lightest-pieces", "darkest-pieces", "warm-golden", "cool-smoky"]
        #expect(ConsultInspirationAnswering.toggle(
            "copper-red", in: selection, question: question
        ) == selection)
        #expect(ConsultInspirationAnswering.toggle(
            "cool-smoky", in: selection, question: question
        ) == ["lightest-pieces", "darkest-pieces", "warm-golden"])

        // The free-text question: a blank note with no selection means
        // "nothing else" — the server refuses the answer otherwise.
        let texting = try decode(
            ConsultInspirationStateResponse.self, key: "inspirationTextQuestion"
        ).inspiration
        let textQuestion = try #require(texting.progress.currentQuestion)
        #expect(ConsultInspirationAnswering.effectiveValues(
            question: textQuestion, selected: [], trimmedText: ""
        ) == ["nothing-else"])
        #expect(ConsultInspirationAnswering.effectiveValues(
            question: textQuestion, selected: [], trimmedText: "love the shine"
        ) == [])
        #expect(ConsultInspirationAnswering.effectiveValues(
            question: textQuestion, selected: ["nothing-else"], trimmedText: ""
        ) == ["nothing-else"])
    }

    @Test func inspirationTextRulesRefuseTraitLanguageAndMirrorTheServerCap() {
        #expect(ConsultInspirationTextRules.maxCharacters == 240)
        for blocked in [
            "I love the framing around the FACE",
            "would this suit my skin tone?",
            "makes her eyes pop",
            "good for my body type",
        ] {
            #expect(ConsultInspirationTextRules.containsUnsupportedTraitLanguage(blocked))
        }
        for allowed in [
            "love the copper ribbons through the lengths",
            "the shadow root feels too heavy for me",
            "the money pieces brighten the whole look",
        ] {
            #expect(!ConsultInspirationTextRules.containsUnsupportedTraitLanguage(allowed))
        }
    }

    @Test func analysisPrerequisiteCodesMapToActionableContentFreeMessages() {
        let cases: [(String, ConsultClientFailure)] = [
            ("CONSULT_ANALYSIS_PREREQUISITES_REQUIRED", .analysisPrerequisitesRequired),
            ("CONSULT_ANALYSIS_CAPTURES_REQUIRED", .analysisCapturesRequired),
            ("CONSULT_ANALYSIS_INSPIRATION_REQUIRED", .analysisInspirationRequired),
        ]
        let privateContent = "consult-raw/v1/private.jpg"
        for (code, expected) in cases {
            let mapped = ConsultClientFailure.stable(APIError.server(
                status: 409, message: privateContent, code: code
            ))
            #expect(mapped == expected)
            #expect(!mapped.message.contains(privateContent))
        }
        #expect(Set(cases.map(\.1.message)).count == cases.count)
    }
}
