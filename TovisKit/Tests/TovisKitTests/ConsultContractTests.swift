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

    /// P5a — the THREAD, decoded off the same fixture the cross-repo contract
    /// guard validates against the web's generated API schema.
    ///
    /// 🔴 The message union is what this exists for. Two different question
    /// TYPES are served under the same key `question` (the intake pack's on a
    /// QUESTION message, the inspiration pack's on an INSPIRATION message), so
    /// `ConsultThreadMessage` decodes both by hand — and a hand-written decoder
    /// that quietly stopped reading one of them would look exactly like a
    /// feature that was never built.
    @Test func decodesTheConsultThread() throws {
        let thread = try decode(ConsultThreadResponse.self, key: "thread").thread

        #expect(thread.consultId == "consult_fixture_1")
        #expect(thread.status == .mediaReady)
        // The pro is NAMED on the wire, honoring her display preference — the
        // field "help <pro> get ready" needs and no consult DTO carried before.
        #expect(thread.professionalDisplayName == "Susie")

        // Every kind in the union decodes, and none lands as `.unknown`.
        let kinds = Set(thread.messages.map(\.kind))
        #expect(
            kinds == [
                .text, .consent, .question, .inspiration, .photoRequest,
                .plan, .planUpdate, .booking, .followUp,
            ]
        )
        #expect(!thread.messages.contains { $0.kind == .unknown })

        // P7a-3 — the plan is VERSIONED, and the version bubble carries the DIFF.
        //
        // 🔴 `changes` is asserted non-empty here on purpose. The field is
        // optional on the wire (an older build must survive it) and an optional
        // array that silently decodes to nil looks exactly like a bubble the
        // server sent with nothing in it — which is a real and different state
        // the server has its own sentence for.
        let planCard = try #require(thread.messages.first { $0.kind == .plan })
        #expect(planCard.planVersion == 2)
        #expect(planCard.updatePending == false)

        let update = try #require(thread.messages.first { $0.kind == .planUpdate })
        #expect(update.planVersion == 2)
        #expect(update.previousPlanVersion == 1)
        let changes = try #require(update.changes)
        #expect(changes.map(\.key) == ["achievability", "steps"])
        // The words are the SERVER's, rendered verbatim — the pro's Brief shows
        // these same labels, and a device that re-worded them would be the
        // disagreement a versioned Brief exists to prevent.
        #expect(changes.first?.label == "How big a job it is")
        #expect(changes.first?.from == "One visit")
        #expect(changes.first?.to == "More than one visit")

        // The resume pointer names a message that is actually in the thread and
        // actually open — the whole of "reopening resumes at the next step".
        let open = try #require(thread.messages.first { $0.id == thread.nextOpenMessageId })
        #expect(open.state == .open)

        // 🔴 BOTH question types come back, off the same wire key.
        let intakeQuestion = try #require(
            thread.messages.first { $0.kind == .question }?.question
        )
        #expect(!intakeQuestion.options.isEmpty)
        // 🔴 P5d: the inspiration STEP message carries no question. Its
        // questions moved onto CARD messages, and serving the same question on
        // both would render it twice. The question comes back off the same wire
        // key as the intake one — the reason this decoder is hand-written — but
        // it arrives on the card.
        let inspirationStep = try #require(
            thread.messages.first { $0.kind == .inspiration && $0.card == nil }
        )
        #expect(inspirationStep.inspirationQuestion == nil)
        #expect(inspirationStep.schemaVersion != nil)

        // A CARD carries its crop, its plain word, its question, and the tier
        // that decides where in the thread it belongs.
        let cards = thread.messages.compactMap(\.card)
        // P5g adds a third: the region picker, which is also PREP. The two prep
        // cards here are deliberately of DIFFERENT presentations — a v2 consult
        // pinned to the eight `attr_*` cards and a v3 one on the two region
        // moves both have to render, and this fixture carries one of each.
        #expect(cards.map(\.tier) == [.coarse, .prep, .prep])
        #expect(
            cards.map(\.presentation) == [.crop, .crop, .regionPicker]
        )
        let coarse = try #require(cards.first { $0.tier == .coarse })
        // The coarse card's OPTIONS crop to different parts of one photograph;
        // two of the four are about the whole picture and carry no region.
        #expect(
            coarse.optionRegions.filter { $0.region != nil }.map(\.value)
                == ["the-color", "the-shape"]
        )
        #expect(coarse.name == nil)
        let prep = try #require(cards.first { $0.presentation == .crop && $0.tier == .prep })
        #expect(prep.attribute == "tone")
        #expect(prep.attributeValue == "COOL")
        #expect(prep.region != nil)
        // The plain word, which the SERVER chose — the device composes nothing.
        #expect(prep.name?.contains("some people call it ash") == true)
        // 🔴 A card message has no bubble of its own.
        #expect(thread.messages.first { $0.card != nil }?.text == nil)

        // A photo request carries its shot, its served slot and the versions its
        // upload must echo.
        let photo = try #require(thread.messages.first { $0.kind == .photoRequest })
        #expect(photo.shot != nil)
        #expect(photo.slot != nil)
        #expect(photo.shotPackVersion != nil)
        #expect(photo.schemaVersion != nil)

        // The plan card carries the run AND the results.
        let plan = try #require(thread.messages.first { $0.kind == .plan })
        #expect(plan.run != nil)
        #expect(plan.results?.recommendationDirections.isEmpty == false)

        // The sticky CTA carries what the ORDINARY look-booking path needs, so
        // the button does not have to go and find it.
        #expect(thread.book.enabled)
        #expect(thread.book.serviceId != nil)
        #expect(thread.book.lookMediaId != nil)
        // P7a-5 — the money line arrives COMPOSED. The device must not be able
        // to reassemble it, so what is asserted is that the whole sentence
        // survives the wire, not that two numbers did.
        #expect(thread.book.priceNote == "From $180 · $25.00 deposit")
        #expect(thread.book.gateNote == nil)
    }

    /// P7a-5 — the prep gate decodes, and the CTA it produces is one the client
    /// can clear herself.
    ///
    /// 🔴 INLINE JSON, deliberately NOT the contract fixture. `PREP_REQUIRED` is
    /// a new member of an enum union, and a fixture carrying it would match no
    /// arm of the web's CURRENT schema — reddening this repo's contract check
    /// the moment it landed and forcing a three-landing dance for a case a unit
    /// test can prove on its own. A new PROPERTY (priceNote/gateNote above) has
    /// no such problem, which is why those DO ride the fixture.
    @Test func decodesThePrepRequiredBookGate() throws {
        let cta = try decode(
            ConsultThreadBookCta.self,
            value: [
                "enabled": false,
                "reason": "PREP_REQUIRED",
                "lookPostId": "look_1",
                "serviceId": "service_1",
                "lookMediaId": "media_1",
                "priceNote": "From $180 · 20% deposit",
                "gateNote": "Susie asks clients to finish a few questions first.",
            ] as [String: Any]
        )

        #expect(cta.reason == .prepRequired)
        #expect(!cta.enabled)
        // The gate note is SERVER copy — it names the pro, so there is no local
        // string for it and nothing here may invent one.
        #expect(cta.gateNote == "Susie asks clients to finish a few questions first.")
        // A percentage deposit stays a percentage. At the spark there is no
        // location mode and no add-ons, so dollars would be a guess.
        #expect(cta.priceNote?.contains("20% deposit") == true)
    }

    /// A build that meets a gate reason it has never heard of still renders the
    /// bar, rather than failing the whole thread decode.
    @Test func anUnknownBookGateReasonDecodesAsUnknown() throws {
        let cta = try decode(
            ConsultThreadBookCta.self,
            value: [
                "enabled": false,
                "reason": "SOMETHING_NEW",
                "lookPostId": "look_1",
                "serviceId": "service_1",
                "lookMediaId": "media_1",
                "priceNote": nil as String? as Any,
                "gateNote": nil as String? as Any,
            ] as [String: Any]
        )

        #expect(cta.reason == .unknown)
    }

    /// A build that meets a message kind it has never heard of renders the rest
    /// of the thread rather than failing the whole decode.
    @Test func anUnknownThreadMessageKindDecodesAsUnknown() throws {
        var envelope = try #require(try root()["thread"] as? [String: Any])
        var thread = try #require(envelope["thread"] as? [String: Any])
        var messages = try #require(thread["messages"] as? [[String: Any]])
        messages.append([
            "kind": "ZOOM_CARD", "id": "zoom:1", "author": "APP", "state": "OPEN",
        ])
        thread["messages"] = messages
        envelope["thread"] = thread

        let decoded = try decode(ConsultThreadResponse.self, value: envelope).thread
        #expect(decoded.messages.last?.kind == .unknown)
        #expect(decoded.messages.count == messages.count)
    }

    /// P5g — the FOLLOW_UP message, off the contract fixture.
    ///
    /// It moved here from an inline JSON string once tovis-app merged: FOLLOW_UP
    /// is a new member of the `ConsultThreadMessageDTO` union, so a fixture
    /// carrying one could not validate against the backend schema on `main`
    /// until that schema knew about it. The inline version proved the decoder
    /// through the window; this proves the WIRE.
    @Test func decodesAnAdaptiveFollowUpMessage() throws {
        let thread = try decode(ConsultThreadResponse.self, key: "thread").thread
        let followUps = thread.messages.filter { $0.kind == .followUp }
        #expect(followUps.count == 2)

        let generated = try #require(followUps.first)
        #expect(generated.questionKey == "prior_lightening")
        #expect(generated.followUpOptions?.count == 4)
        #expect(generated.fallback == false)
        #expect(generated.round == 1)
        #expect(generated.selectedValues == [])
        // The question is the MODEL's sentence, carried verbatim — the device
        // composes none of it.
        #expect(generated.text?.contains("light brown") == true)
        // 🔴 And it names something specific it was told. A question that would
        // be the same for everybody is the question P5g exists to delete.
        #expect(generated.text?.contains("loved the ash") == true)

        let fallback = try #require(followUps.last)
        // 🔴 The fallback is visible to the client, which is why this flag is on
        // the wire: Part 0 rule 4 forbids a silent fallback, and one she cannot
        // see is a silent one. The server also sends its own bubble saying so.
        #expect(fallback.fallback == true)
        #expect(fallback.round == 2)
        #expect(
            thread.messages.contains {
                $0.kind == .text
                    && $0.text?.contains("couldn’t think of the next question") == true
            }
        )
    }

    /// P5g — a region-picker card decodes, and a card WITHOUT `presentation`
    /// still decodes as a crop card.
    ///
    /// The second half is the one worth having: `presentation` is required on
    /// the wire from P5g on, but a build that meets an older server (or a
    /// replayed fixture) must render the question with buttons rather than
    /// render nothing.
    @Test func decodesARegionPickerCardAndDefaultsAMissingPresentation() throws {
        let state = try decode(
            ConsultInspirationStateResponse.self, key: "inspirationQuestion"
        ).inspiration
        let cards = try #require(state.cards)

        let picker = try #require(cards.first { $0.questionKey == "love_regions" })
        #expect(picker.presentation == .regionPicker)
        #expect(picker.tier == .prep)
        // 🔴 The picker draws boxes over the WHOLE reference, so the card's own
        // region is nil — a crop here would move every box off the part of the
        // photograph it was measured against.
        #expect(picker.region == nil)
        #expect(picker.optionRegions.filter { $0.region != nil }.count == 3)
        // The neutral option carries no region: "not sure" is about the whole
        // picture and is always offered, including when nothing could be read.
        #expect(picker.optionRegions.filter { $0.region == nil }.count == 1)
        // Every region option's label describes THIS photograph rather than
        // naming a category — that is what makes it tappable without jargon.
        #expect(picker.optionRegions.contains { $0.label == "cool, silvery cast" })

        let crop = try #require(cards.first { $0.questionKey == "attr_tone" })
        #expect(crop.presentation == .crop)

        var raw = try #require(try root()["inspirationQuestion"] as? [String: Any])
        var inspiration = try #require(raw["inspiration"] as? [String: Any])
        var rawCards = try #require(inspiration["cards"] as? [[String: Any]])
        rawCards = rawCards.map { card in
            var copy = card
            copy.removeValue(forKey: "presentation")
            return copy
        }
        inspiration["cards"] = rawCards
        raw["inspiration"] = inspiration
        let older = try decode(ConsultInspirationStateResponse.self, value: raw).inspiration
        #expect(try #require(older.cards).allSatisfy { $0.presentation == .crop })
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
        // P6 — the intake diet. The colour pack is v3 and asks only what the
        // analysis cannot read off the photographs.
        #expect(intake.questionPack.version == 3)
        #expect(intake.questionPack.questions.count == 7)
        #expect(intake.questionPack.questions.first { $0.key == "box_dye_history" } != nil)
        #expect(intake.questionPack.questions.first { $0.key == "current_color" } == nil)
        // The service the consult is about, named on the wire at last (B6).
        let service = try #require(intake.service)
        #expect(service.serviceId == "service_fixture_1")
        #expect(service.name == "Signature Balayage")
        #expect(service.proFacingName == "Balayage")
        // Nullable together, and the whole object is optional, so a fixture
        // written before it — and a Look whose service row is gone — decode.
        var noService = try #require(try root()["intake"] as? [String: Any])
        var noServiceInner = try #require(noService["intake"] as? [String: Any])
        noServiceInner.removeValue(forKey: "service")
        noService["intake"] = noServiceInner
        #expect(
            try decode(ConsultIntakeStateResponse.self, value: noService).intake.service == nil
        )

        let capture = try decode(ConsultCaptureStateResponse.self, key: "capture").capture
        #expect(capture.shotPack.shots.map(\.key) == ConsultCaptureShotKey.hairPack)
        #expect(capture.hasAllAcceptedShots)

        let analysis = try decode(ConsultAnalysisStartResponse.self, key: "analysis").analysis
        #expect(analysis.status == .completed)
        #expect(analysis.schemaVersion == 3)
        #expect(analysis.promptVersion == "service-analysis-v3")

        let results = try decode(ConsultClientResultsResponse.self, key: "results").results
        #expect(results.hasFaithfulClientContract)
        // Additive brand heading — present here, optional on the wire.
        #expect(results.directionsTitle == "Directions to discuss")
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

    /// Exposure is server-decided (GET /client/consult/availability): the
    /// device shows an entry point only on an explicit `available: true` and
    /// never re-derives the gate locally. All three server answers decode —
    /// open with an existing session, open with none, and dark.
    @Test func availabilityContractCarriesAllThreeServerAnswers() throws {
        let root = try #require(
            JSONSerialization.jsonObject(with: fixture("consultAvailability")) as? [String: Any]
        )

        let openWithSession = try decode(
            ConsultAvailabilityResponse.self,
            value: #require(root["openWithSession"])
        ).availability
        #expect(openWithSession.available)
        #expect(openWithSession.consult?.id == "consult_fixture_1")
        #expect(openWithSession.consult?.status == .consentRequired)

        let openNoSession = try decode(
            ConsultAvailabilityResponse.self,
            value: #require(root["openNoSession"])
        ).availability
        #expect(openNoSession.available)
        #expect(openNoSession.consult == nil)

        let dark = try decode(
            ConsultAvailabilityResponse.self,
            value: #require(root["dark"])
        ).availability
        #expect(!dark.available)
        #expect(dark.consult == nil)
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

        // 🔴 A LOOK-anchored source names the SAME per-consult read route as an
        // upload. `imageReadEndpoint` is a typed contract — whatever it carries
        // must answer `{ url, expiresInSeconds }` — and it used to fork here and
        // point at `/api/v1/looks/{id}`, which answers a look DTO. That is B4:
        // the likes/dislikes step with nothing on screen.
        let lookSourced = try decode(
            ConsultInspirationStateResponse.self, key: "inspirationLookSourceQuestion"
        ).inspiration
        let lookSource = try #require(lookSourced.source)
        #expect(lookSource.source == "PLATFORM_LOOK")
        #expect(lookSource.lookPostId == "look_fixture_1")
        #expect(lookSource.imageAvailable)
        #expect(lookSource.useExpiresAt == nil)
        #expect(lookSource.imageReadEndpoint == source.imageReadEndpoint)

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

    // MARK: - Pre-deploy fixes (2026-09-03)

    /// The server's rule, not a stricter local one: only REQUIRED blocks on
    /// its own. The previous build labelled CONDITIONAL "Required" and refused
    /// to submit without it — a demand the web never makes.
    @Test func onlyRequiredMustBeAnsweredLocally() {
        #expect(ConsultIntakeRequirement.required.mustAnswer)
        #expect(!ConsultIntakeRequirement.conditional.mustAnswer)
        #expect(!ConsultIntakeRequirement.skippable.mustAnswer)
        #expect(!ConsultIntakeRequirement.unknown.mustAnswer)
    }

    /// The served progress is what the submit gate prefers; a fixture written
    /// before it existed still decodes (`progress` is optional here only).
    @Test func intakeProgressDecodesWhenServed() throws {
        let intake = try decode(ConsultIntakeStateResponse.self, key: "intake").intake
        let progress = try #require(intake.progress)
        #expect(progress.canComplete == false)
        #expect(progress.nextQuestionKey == "change_scale")
        #expect(progress.blocker == "REQUIRED_ANSWERS_MISSING")

        var stripped = try #require(try root()["intake"] as? [String: Any])
        var inner = try #require(stripped["intake"] as? [String: Any])
        inner.removeValue(forKey: "progress")
        stripped["intake"] = inner
        let legacy = try decode(ConsultIntakeStateResponse.self, value: stripped).intake
        #expect(legacy.progress == nil)
    }

    /// A pack describes itself by its shot KEYS, so the capture header can
    /// name "four hair views and three face views" for the hair pack and
    /// "the area … and your face" for a pack this build has never seen.
    @Test func shotPackDescribesItselfByKeys() throws {
        let hair = try decode(ConsultCaptureStateResponse.self, key: "capture").capture.shotPack
        #expect(hair.hairViewCount == 4)
        #expect(hair.faceViewCount == 3)
        #expect(hair.areaViewCount == 0)

        let area = try decode(ConsultCaptureShotPack.self, value: [
            "id": "area-daylight", "categorySlug": "nails", "version": 1, "schemaVersion": 1,
            "shots": [
                ["key": "area_wide", "title": "The area", "instruction": "", "requirement": "REQUIRED"],
                ["key": "area_closeup", "title": "Close up", "instruction": "", "requirement": "REQUIRED"],
                ["key": "face_front", "title": "Face front", "instruction": "", "requirement": "REQUIRED"],
            ],
        ] as [String: Any])
        #expect(area.areaViewCount == 2)
        #expect(area.faceViewCount == 1)
        #expect(area.hairViewCount == 0)
        #expect(area.shots.count == 3)
    }

    /// Absent on an older server, the heading is nil and the view falls back.
    @Test func directionsTitleIsOptionalOnTheWire() throws {
        var response = try #require(try root()["results"] as? [String: Any])
        var results = try #require(response["results"] as? [String: Any])
        results.removeValue(forKey: "directionsTitle")
        response["results"] = results
        let decoded = try decode(ConsultClientResultsResponse.self, value: response).results
        #expect(decoded.directionsTitle == nil)
        #expect(decoded.hasFaithfulClientContract)
    }
}
