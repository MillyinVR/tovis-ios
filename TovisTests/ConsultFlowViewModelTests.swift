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
    /// The last intake revision this mock accepted, so its thread can render the
    /// answered questions as history the way the server's projection does.
    private var latestIntakeAnswers: [String: String] = [:]
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
        try await submitIntake(
            consultId: consultId,
            packVersion: state.questionPack.version,
            schemaVersion: state.questionPack.schemaVersion,
            answers: answers,
            complete: true,
            idempotencyKey: idempotencyKey
        )
    }

    func submitIntake(consultId: String, packVersion: Int, schemaVersion: Int,
                      answers: [String: String], complete: Bool,
                      idempotencyKey: String) async throws -> ConsultIntakeState {
        latestIntakeAnswers = answers
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

    /// P5g — every follow-up answer this double was asked to file, in order.
    /// Recorded rather than discarded so a test can assert the device sent the
    /// KEY and the ENUM and decided no routing of its own.
    private(set) var answeredFollowUps: [(key: String, values: [String])] = []

    func answerFollowUp(consultId: String, questionKey: String,
                        selectedValues: [String],
                        idempotencyKey: String) async throws {
        answeredFollowUps.append((questionKey, selectedValues))
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
    private var threadError: Error?
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

    // MARK: - The thread (P5a)
    //
    // A test-only stand-in for the SERVER's projection
    // (tovis-app `lib/consult/thread.ts`), composed from the states this mock
    // already models. It is a mock of a server response, not a second
    // implementation of the rule: the real ordering, the real open-step pointer
    // and the real Book gate are proven against real PostgreSQL in tovis-app
    // `tests/integration/consult-thread.test.ts`. What THIS stands up is the
    // view model — that it renders, mutates and resumes off a served thread.

    func thread(consultId: String) async throws -> ConsultThread {
        if let threadError { throw threadError }
        var messages: [[String: Any]] = [
            message("TEXT", "opening", state: "DONE", extra: [
                "text": "Love this one. Let’s work out what it would take on you.",
            ]),
        ]

        let agreements = try agreementDictionary()
        var consentRequirements = try #require(agreements["requirements"] as? [[String: Any]])
        for index in consentRequirements.indices {
            let raw = consentRequirements[index]["kind"] as? String
            let kind = raw.flatMap(ConsultAgreementKind.init(rawValue:))
            if kind.map({ !acceptedKinds.contains($0) }) ?? true {
                consentRequirements[index]["currentAcceptance"] = NSNull()
            }
        }
        let consentOutstanding = acceptedKinds.count < 2
        messages.append(message("CONSENT", "consent",
                                state: consentOutstanding ? "OPEN" : "DONE",
                                extra: [
                                    "text": "Quick bit first: two things to agree to before any photos.",
                                    "requirements": consentRequirements,
                                ]))

        if !consentOutstanding {
            messages.append(contentsOf: try intakeMessages())
            messages.append(try inspirationMessage())
            messages.append(contentsOf: try photoMessages())
            messages.append(try planMessage())
        }

        let nextOpen = messages.first { $0["state"] as? String == "OPEN" }?["id"] as? String
        let selfieIn = acceptedShots.contains(.faceFront)

        return try decode(ConsultThread.self, value: [
            "consultId": consultId,
            "status": threadStatus(consentOutstanding: consentOutstanding),
            "professionalId": sessionProfessionalId,
            "professionalDisplayName": "Susie",
            "nextOpenMessageId": nextOpen ?? NSNull(),
            "messages": messages,
            "chartCopy": (consentOutstanding
                ? NSNull()
                : ["optIn": true, "decidedAt": NSNull()] as [String: Any]) as Any,
            "book": [
                "enabled": selfieIn,
                "reason": (selfieIn ? NSNull() : "SELFIE_REQUIRED") as Any,
                "lookPostId": "look_fixture_1",
                "serviceId": "service_fixture_1",
                "lookMediaId": "media_fixture_1",
            ],
        ] as [String: Any])
    }

    private func threadStatus(consentOutstanding: Bool) -> String {
        if consentRevoked { return "CONSENT_REVOKED" }
        if consentOutstanding { return "CONSENT_REQUIRED" }
        if latestIntakeAnswers.isEmpty { return "INTAKE_READY" }
        if analysisStarted { return "COMPLETED" }
        return sessionAdvancedToAnalysis ? "ANALYSIS_PENDING" : "MEDIA_READY"
    }

    private func intakeMessages() throws -> [[String: Any]] {
        let intake = dictionary("intake", "intake")
        let pack = try #require(intake["questionPack"] as? [String: Any])
        let questions = try #require(pack["questions"] as? [[String: Any]])
        var out: [[String: Any]] = []
        var openTaken = false
        for question in questions {
            let key = try #require(question["key"] as? String)
            let answer = latestIntakeAnswers[key]
            // Everything after the open question is still unasked — a thread
            // shows history plus the one thing being asked, never a form.
            if answer == nil && openTaken { continue }
            let isOpen = answer == nil && !openTaken
            if isOpen { openTaken = true }
            out.append(message("QUESTION", "intake:\(key)",
                               state: isOpen ? "OPEN" : "DONE",
                               extra: [
                                   "question": question,
                                   "answer": answer ?? NSNull(),
                                   "packVersion": pack["version"] ?? 1,
                                   "schemaVersion": pack["schemaVersion"] ?? 1,
                               ]))
        }
        return out
    }

    private func inspirationMessage() throws -> [String: Any] {
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
        let state = dictionary(key, "inspiration")
        let progress = try #require(state["progress"] as? [String: Any])
        let question = progress["currentQuestion"]
        let complete = inspirationComplete && !(question is [String: Any])
        return message("INSPIRATION", "inspiration",
                       state: complete ? "DONE" : "OPEN",
                       extra: [
                           "text": "Now tell me what you like about it.",
                           "sourceDecisionRequired": inspirationSource == nil,
                           "source": state["source"] ?? NSNull(),
                           "question": question ?? NSNull(),
                           "answeredQuestionCount": min(inspirationAnsweredCount, 7),
                           "specificDetailCount": progress["specificDetailCount"] ?? 0,
                           "requiredSpecificDetailCount": 3,
                           "schemaVersion": state["schemaVersion"] ?? 1,
                       ])
    }

    private func photoMessages() throws -> [[String: Any]] {
        let capture = try captureDictionary(rejectedShot: rejectedShotKey)
        let pack = try #require(capture["shotPack"] as? [String: Any])
        let shots = try #require(pack["shots"] as? [[String: Any]])
        let slots = try #require(capture["slots"] as? [[String: Any]])
        var out: [[String: Any]] = []
        var openTaken = false
        for shot in shots {
            let key = try #require(shot["key"] as? String)
            let slot = slots.first { $0["shotKey"] as? String == key }
            let settled = (slot?["state"] as? String) == "ACCEPTED"
            let isOpen = !settled && !openTaken
            if isOpen { openTaken = true }
            out.append(message("PHOTO_REQUEST", "photo:\(key)",
                               state: settled ? "DONE" : (isOpen ? "OPEN" : "BLOCKED"),
                               extra: [
                                   "shot": shot,
                                   "shotPackVersion": pack["version"] ?? 2,
                                   "schemaVersion": pack["schemaVersion"] ?? 1,
                                   "slot": slot ?? NSNull(),
                               ]))
        }
        return out
    }

    private func planMessage() throws -> [String: Any] {
        let value = dictionary("analysis", "analysis")
        // Mirrors the server: the run is present only once one exists — the
        // fixture's analysis always carries a COMPLETED run, and treating that
        // as "there is a run" would mean the plan card never offered a start.
        var run: Any = NSNull()
        if !scriptedRuns.isEmpty {
            run = scriptedRuns.count > 1 ? scriptedRuns.removeFirst() : scriptedRuns[0]
        } else if analysisStarted {
            run = value["run"] ?? NSNull()
        }
        let runStatus = (run as? [String: Any])?["status"] as? String
        let awaitingStart = sessionAdvancedToAnalysis && !analysisStarted
        let completed = analysisStarted && (runStatus ?? "COMPLETED") == "COMPLETED"
        return message("PLAN", "plan",
                       state: completed ? "DONE" : (awaitingStart ? "OPEN" : "BLOCKED"),
                       extra: [
                           "text": "Here’s where you’re starting from.",
                           "run": run,
                           "results": (completed
                               ? dictionary("results", "results")
                               : NSNull()) as Any,
                           "awaitingStart": awaitingStart,
                           "schemaVersion": value["schemaVersion"] ?? 3,
                           "promptVersion": value["promptVersion"] ?? "v4",
                       ])
    }

    private func message(_ kind: String, _ id: String, state: String,
                         extra: [String: Any]) -> [String: Any] {
        var value: [String: Any] = [
            "kind": kind, "id": id, "author": "APP", "state": state,
        ]
        for (key, entry) in extra { value[key] = entry }
        return value
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

    // ── Reading the thread ───────────────────────────────────────────────────
    //
    // The flow is a message list now, so the assertions below ask the THREAD
    // what is on screen rather than asking the view model for a stage. That is
    // the point of P5a: there is no local stage to disagree with the server.

    private func messages(
        _ model: ConsultFlowViewModel, _ kind: ConsultThreadMessage.Kind
    ) -> [ConsultThreadMessage] {
        model.messages.filter { $0.kind == kind }
    }

    private func openMessage(_ model: ConsultFlowViewModel) -> ConsultThreadMessage? {
        model.messages.first { $0.id == model.nextOpenMessageId }
    }

    private func consentRequirements(
        _ model: ConsultFlowViewModel
    ) -> [ConsultAgreementRequirement] {
        messages(model, .consent).first?.requirements ?? []
    }

    private func photoMessage(
        _ model: ConsultFlowViewModel, _ key: ConsultCaptureShotKey
    ) -> ConsultThreadMessage? {
        messages(model, .photoRequest).first { $0.shot?.key == key }
    }

    private func slot(
        _ model: ConsultFlowViewModel, _ key: ConsultCaptureShotKey
    ) -> ConsultCaptureSlot? {
        photoMessage(model, key)?.slot
    }

    private func inspirationMessage(_ model: ConsultFlowViewModel) -> ConsultThreadMessage? {
        messages(model, .inspiration).first
    }

    private func planMessage(_ model: ConsultFlowViewModel) -> ConsultThreadMessage? {
        messages(model, .plan).first
    }

    /// Answer both agreements, whatever order the thread serves them in.
    private func acceptBothAgreements(_ model: ConsultFlowViewModel) async throws {
        for kind in [ConsultAgreementKind.sensitiveDataConsent, .adult18PlusAttestation] {
            let requirement = try #require(consentRequirements(model).first { $0.kind == kind })
            await model.accept(requirement)
        }
    }

    /// Tap through the intake by answering ONLY the question the thread is
    /// currently offering — which is what "one question per message" means.
    @discardableResult
    private func answerWholeIntake(_ model: ConsultFlowViewModel) async throws -> Int {
        var taps = 0
        while let open = openMessage(model), open.kind == .question {
            let question = try #require(open.question)
            await model.answerIntake(open, value: try #require(question.options.first?.value))
            taps += 1
            #expect(taps <= 30, "intake did not terminate")
        }
        return taps
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
        _ model: ConsultFlowViewModel, _ jpeg: Data, for message: ConsultThreadMessage
    ) async {
        await model.submitPhoto(jpeg, for: message)
        await model.uploads.settle()
        await model.refreshThread()
    }

    private func model(_ service: MockConsultService,
                       uploads: ConsultCaptureUploadQueue? = nil) -> ConsultFlowViewModel {
        ConsultFlowViewModel(
            anchor: .booking("booking_fixture_1"),
            professionalId: "cmq9p645v0002jp04fttoatlq",
            service: service,
            uploads: uploads
        )
    }

    @Test func completeMockedGuidedBookingConsultFlowIncludesLocalAndServerRetakes() async throws {
        try await withCaptureVault("flow-full") {
            let service = MockConsultService(root: try fixtureRoot())
            let model = model(service, uploads: await testQueue(service))

            await model.start()
            // The thread opens on consent, and consent is the one open step.
            #expect(openMessage(model)?.kind == .consent)
            #expect(messages(model, .question).isEmpty)
            try await acceptBothAgreements(model)

            // Now the intake, one question per message.
            #expect(openMessage(model)?.kind == .question)
            try await answerWholeIntake(model)
            // Every answered question stays on screen as history carrying the
            // client's own answer — the difference between a thread and a form.
            #expect(messages(model, .question).allSatisfy { $0.answer != nil })
            #expect(inspirationMessage(model)?.sourceDecisionRequired == true)

            let guidedPipeline = ConsultTransientPhotoPipeline(
                quality: FirstSoftThenPassingConsultQC(),
                preparation: IdentityConsultJPEGPreparation()
            )
            let back = try #require(photoMessage(model, .hairBack))
            let localFailure = await guidedPipeline.process(
                Data("soft-back".utf8),
                expectations: ConsultShotGuidance.expectations(for: .hairBack)
            )
            #expect(localFailure == .retake("It came out soft"))
            #expect(await service.receivedByteCounts.isEmpty)

            let firstBack = await guidedPipeline.process(
                Data("first-back".utf8),
                expectations: ConsultShotGuidance.expectations(for: .hairBack)
            )
            guard case let .accepted(firstBackJPEG) = firstBack else {
                Issue.record("Guided post-capture QC should accept the retry")
                return
            }
            await submit(model, firstBackJPEG, for: back)
            // The server's refusal reaches the client ON the photo message.
            #expect(slot(model, .hairBack)?.state == .rejected)
            #expect(slot(model, .hairBack)?.retakeTip != nil)

            let serverRetake = await guidedPipeline.process(
                Data("retake-back".utf8),
                expectations: ConsultShotGuidance.expectations(for: .hairBack)
            )
            guard case let .accepted(serverRetakeJPEG) = serverRetake else {
                Issue.record("Guided QC should accept the server-requested retake")
                return
            }
            await submit(model, serverRetakeJPEG, for: try #require(photoMessage(model, .hairBack)))

            for key in ConsultCaptureShotKey.hairPack where key != .hairBack {
                let outcome = await guidedPipeline.process(
                    Data("photo-\(key.rawValue)".utf8),
                    expectations: ConsultShotGuidance.expectations(for: key)
                )
                guard case let .accepted(jpeg) = outcome else {
                    Issue.record("Every deterministic guided shot should pass local QC")
                    return
                }
                await submit(model, jpeg, for: try #require(photoMessage(model, key)))
            }

            // 7/7 accepted but the inspiration review is still open: the server
            // holds the session at MEDIA_READY, and the client must not jump
            // ahead locally.
            #expect(model.acceptedShotCount == 7)
            #expect(!model.canOfferPartialContinue)
            #expect(planMessage(model)?.awaitingStart != true)

            // 🔴 The selfie is in, so the spark is bookable — with no analysis,
            // no estimate and the flow still mid-prep.
            #expect(model.thread?.book.enabled == true)

            await model.uploadInspirationPhoto(
                try #require(inspirationMessage(model)), Data("inspiration-look".utf8)
            )
            var answeredRounds = 0
            while let message = inspirationMessage(model),
                  let question = message.inspirationQuestion,
                  answeredRounds < 10 {
                answeredRounds += 1
                let values = question.kind == .text
                    ? []
                    : [try #require(question.options.first?.value)]
                await model.answerInspiration(
                    message, question: question, selectedValues: values
                )
            }
            #expect(answeredRounds == 7)
            #expect(inspirationMessage(model)?.state == .done)
            #expect(await service.inspirationUploadByteCounts == [Data("inspiration-look".utf8).count])
            #expect(await service.answeredInspirationKeys.count == 7)

            // The completed review advances the session server-side; the thread
            // follows it rather than deciding locally.
            #expect(planMessage(model)?.awaitingStart == true)

            await model.startAnalysis()
            let plan = try #require(planMessage(model))
            let results = try #require(plan.results)
            #expect(results.clientIntake.first?.questionKey == "desired_color")
            #expect(results.safetyFlags.first?.code == "RECENT_BOX_DYE")
            #expect(results.recommendationDirections.count == 2)
            #expect(results.meCardTeaser.locked == true)
            // 🔴 The provenance check still runs on a results payload that now
            // arrives inside a message.
            #expect(!model.resultsContractMismatch)

            await model.tapLockedMeCard()
            #expect(model.teaserTapped)
            #expect(await service.teaserRecorded)
            #expect(await service.receivedByteCounts.count == 8)
            #expect(await guidedPipeline.retainedByteCount() == 0)
            // Eight photographs, eight DISTINCT issue keys — and no more than
            // eight, which is what says a retry replayed its key instead of
            // minting a second upload session and a second paid quality check.
            #expect(await Set(service.issuedKeys).count == 8)
            #expect(await Set(service.qualityKeys).count == 8)
            // Nothing is still owed: every shot's bytes were released.
            #expect(model.uploads.items(consultId: "consult_fixture_1").isEmpty)
            #expect(model.failure == nil)
        }
    }

    @Test func partialPackContinuesThroughProceedOnceInspirationIsDone() async throws {
        try await withCaptureVault("flow-partial") {
            let service = MockConsultService(root: try fixtureRoot())
            let model = model(service, uploads: await testQueue(service))

            await model.start()
            try await acceptBothAgreements(model)
            try await answerWholeIntake(model)

            // Continuing without an inspiration photo is a complete review.
            await model.skipInspiration(try #require(inspirationMessage(model)))
            #expect(inspirationMessage(model)?.state == .done)

            // One accepted photo out of seven unlocks the partial-pack path.
            await submit(model, Data("left".utf8), for: try #require(photoMessage(model, .hairLeft)))
            #expect(model.acceptedShotCount == 1)
            #expect(model.canOfferPartialContinue)
            // A hair shot is not a selfie: the Book gate must not have moved.
            #expect(model.thread?.book.enabled == false)
            #expect(model.thread?.book.reason == .selfieRequired)

            await model.proceedWithAccepted()
            #expect(planMessage(model)?.awaitingStart == true)

            await model.startAnalysis()
            #expect(planMessage(model)?.results != nil)
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
        let model = model(service)
        await model.start()
        // Consent first: the thread serves nothing past it, and a run that
        // existed before consent would not be a state the server can reach.
        try await acceptBothAgreements(model)
        await model.refreshAnalysis()
        // A LIVE run is on the plan card, and the card is not offering a start.
        let first = try #require(planMessage(model)?.run)
        #expect(first.status.isLive)
        #expect(planMessage(model)?.awaitingStart != true)

        // The poll ticks every 5s; drive it by hand instead of sleeping fifteen
        // real seconds in a unit test. Each tick re-reads the THREAD — the plan
        // card is where the run lives now — and the run advances through the
        // scripted stages until it settles.
        //
        // The stages are collected rather than pinned one-per-call: how many
        // thread reads the SETUP costs is the mock's business, and a test that
        // counted them would break every time the flow read the thread once
        // more. What must be true is that polling walks the run forward and
        // stops when it settles.
        var seen: [ConsultAnalysisRunStage] = [first.stage]
        var settled = false
        for _ in 0..<5 where !settled {
            settled = await model.pollOnceForTest()
            if let stage = planMessage(model)?.run?.stage { seen.append(stage) }
        }
        #expect(settled)
        #expect(seen.contains(.buildingPlan))
        #expect(planMessage(model)?.run?.status == .completed)
        // 🔴 A completed run does NOT navigate away. The plan lands in the
        // thread and the thread stays open — that is the difference between a
        // wizard that ends and a consult that continues as prep.
        #expect(!model.messages.isEmpty)
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
        let model = model(service)
        await model.start()
        // Consent first: the thread serves nothing past it, and a run that
        // existed before consent would not be a state the server can reach.
        try await acceptBothAgreements(model)
        await model.refreshAnalysis()

        await service.setThreadErrorForTest(URLError(.timedOut))
        await model.pollOnceForTest()
        #expect(model.failure == nil)
        #expect(model.busy == false)
        // The last good state is still on screen rather than being cleared.
        #expect(planMessage(model)?.run?.stage == .buildingPlan)
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
        let model = model(service)
        await model.start()
        // Consent first: the thread serves nothing past it, and a run that
        // existed before consent would not be a state the server can reach.
        try await acceptBothAgreements(model)
        await model.refreshAnalysis()

        let run = try #require(planMessage(model)?.run)
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

    /// The gate lives server-side: a pro the pilot is dark for gets a 404 from
    /// every consult route, and the device renders that as hidden — no local
    /// copy of the exposure rule exists to disagree with the server.
    @Test func serverHiddenAnswerKeepsTheConsultDark() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        await service.setCreateErrorForTest(
            APIError.server(status: 404, message: "Not found.", code: nil)
        )
        let model = model(service)
        await model.start()
        #expect(model.thread == nil)
        #expect(model.failure == .hidden)
        #expect(model.machine.consultId == nil)
    }

    @Test func revokingSensitiveConsentStopsTheFlow() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        let model = model(service)

        await model.start()
        let sensitive = try #require(consentRequirements(model).first {
            $0.kind == .sensitiveDataConsent
        })
        await model.accept(sensitive)
        await model.revokeSensitiveConsent()

        #expect(await service.consentRevoked)
        #expect(model.thread?.status == .consentRevoked)
        // Nothing in a revoked consult is actionable, so the revoke footer goes.
        #expect(!model.canRevokeConsent)
        #expect(model.failure == nil)
    }

    @Test func serverProfessionalMustMatchTheFounderGatedBooking() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        await service.setSessionProfessionalIdForTest("professional_other")
        let model = model(service)

        await model.start()
        #expect(model.failure == .hidden)
        #expect(model.machine.consultId == nil)
    }

    /// Drives a model as far as an ATTACHED inspiration source, which is the
    /// only state in which the image panel renders.
    private func modelAtInspiration(
        _ service: MockConsultService
    ) async throws -> ConsultFlowViewModel {
        let model = model(service)
        await model.start()
        try await acceptBothAgreements(model)
        try await answerWholeIntake(model)
        await model.uploadInspirationPhoto(
            try #require(inspirationMessage(model)), Data("inspiration".utf8)
        )
        #expect(inspirationMessage(model)?.source?.imageAvailable == true)
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
        let model = model(service)
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

    /// Drives the intake by tapping ONLY the question the thread is currently
    /// offering, and returns how many taps it took to reach the photo step.
    ///
    /// 🔴 The thread costs ONE TAP FEWER than the wizard did: there is no final
    /// "Continue to photos" button, because the photo requests were already in
    /// the thread the whole time. The saved tap is the shape change, not a
    /// change to the pack.
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
        let model = model(service)
        await model.start()
        try await acceptBothAgreements(model)
        #expect(openMessage(model)?.kind == .question)

        let keys = questions.compactMap { $0["key"] as? String }
        var taps = 0
        while let open = openMessage(model), open.kind == .question {
            let question = try #require(open.question)
            // The thread never runs ahead: the open question is always the
            // pack's first unanswered one.
            let answered = Set(
                model.messages.compactMap { $0.answer == nil ? nil : $0.question?.key }
            )
            let expected = keys.first { !answered.contains($0) }
            #expect(
                question.key == expected,
                "tap \(taps): got \(question.key), expected \(expected ?? "nil")"
            )
            await model.answerIntake(open, value: try #require(question.options.first?.value))
            taps += 1
            #expect(taps <= keys.count)
        }
        #expect(taps == keys.count)
        // The photo requests are already on screen — no Continue to press.
        #expect(!messages(model, .photoRequest).isEmpty)
        return taps
    }

    /// The product principle, measured: the consult must feel like an impulse,
    /// not a form.
    @Test func theIntakeDietCutsTheTapsToThePhotoStep() async throws {
        let before = try await tapsToThePhotoStep(
            questions: hairColorV2Questions(), nextQuestionKey: "current_color"
        )
        #expect(before == 15)

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
        #expect(after == 7)
    }

    /// 🔴 The app speaks in ITS OWN voice, and every sentence it says arrives
    /// from the server.
    ///
    /// This is what replaced the old `intakeServiceName` assertion. Naming the
    /// service (handoff B6) moved into the server-composed opening bubble
    /// (`openingWithService` in the brand copy table), so the device's half of
    /// that contract is now "render what you were sent, and never compose a
    /// system sentence locally" — which is what this asserts.
    @Test func everySystemBubbleComesFromTheServer() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        let model = model(service)
        await model.start()

        let opening = try #require(model.messages.first)
        #expect(opening.kind == .text)
        #expect(opening.author == .app)
        #expect(!(opening.text ?? "").isEmpty)
        // The pro is NAMED by the server too, honoring her display preference.
        #expect(model.professionalDisplayName == "Susie")
    }

    /// Reopening a consult resumes at the next open step — the one field that
    /// makes that true, asserted directly.
    @Test func nextOpenMessageIsTheFirstStepStillWaiting() async throws {
        let service = MockConsultService(root: try fixtureRoot())
        let model = model(service)
        await model.start()
        // Before consent there is exactly one thing she can do.
        #expect(model.messages.filter { $0.state == .open }.count == 1)
        #expect(openMessage(model)?.kind == .consent)

        try await acceptBothAgreements(model)
        // 🔴 After consent SEVERAL steps are genuinely open at once — the
        // inspiration review and the photo pack are concurrent on the server,
        // and marking either blocked would be a lie. What must stay true is
        // that `nextOpenMessageId` names where to RESUME, and that it is the
        // FIRST of them in thread order.
        let awaiting = model.messages.filter { $0.state == .open }
        #expect(awaiting.count >= 1)
        #expect(openMessage(model)?.id == awaiting.first?.id)
        #expect(openMessage(model)?.kind == .question)

        try await answerWholeIntake(model)
        // With the intake done the open step moves on, and it is never a
        // question the client has already answered.
        let next = try #require(openMessage(model))
        #expect(next.kind != .question)
    }

    /// A brand-new build meeting a server that learned a new message type must
    /// render the rest of the thread, not crash or blank.
    @Test func anUnknownMessageKindIsSkippedNotFatal() async throws {
        let json = """
        {"kind":"ZOOM_CARD","id":"zoom:1","author":"APP","state":"OPEN"}
        """
        let message = try JSONDecoder().decode(
            ConsultThreadMessage.self, from: Data(json.utf8)
        )
        #expect(message.kind == .unknown)
        #expect(message.id == "zoom:1")
    }

    /// P5d — an inspiration CARD decodes with its crop, its plain word and its
    /// question, and a null `text` is a message with no bubble rather than a
    /// decode failure.
    @Test func anInspirationCardDecodesWithItsCropAndItsWords() throws {
        let json = """
        {"kind":"INSPIRATION","id":"inspiration:attr_tone","author":"APP",
         "state":"OPEN","text":null,"sourceDecisionRequired":false,"source":null,
         "question":{"key":"attr_tone","label":"Is this part of what you like?",
          "helpText":null,"kind":"SINGLE_SELECT","options":[
           {"value":"yes","label":"Yes"},{"value":"not-this","label":"Not this"},
           {"value":"not-sure","label":"Not sure"}],
          "minSelections":1,"maxSelections":1,"allowText":false},
         "card":{"questionKey":"attr_tone","tier":"PREP","attribute":"tone",
          "attributeValue":"COOL",
          "name":"This is the cooler, silvery cast in it.",
          "region":{"x":0.32,"y":0.5,"w":0.36,"h":0.25},"optionRegions":[],
          "question":{"key":"attr_tone","label":"Is this part of what you like?",
           "helpText":null,"kind":"SINGLE_SELECT","options":[
            {"value":"yes","label":"Yes"}],"minSelections":1,"maxSelections":1,
           "allowText":false},
          "selectedValues":["yes"]},
         "answeredQuestionCount":1,"specificDetailCount":1,
         "requiredSpecificDetailCount":0,"schemaVersion":2}
        """
        let message = try JSONDecoder().decode(
            ConsultThreadMessage.self, from: Data(json.utf8)
        )
        #expect(message.kind == .inspiration)
        // 🔴 A card message carries NO bubble. `text` is nullable since P5d.
        #expect(message.text == nil)
        let card = try #require(message.card)
        #expect(card.tier == .prep)
        #expect(card.attribute == "tone")
        #expect(card.attributeValue == "COOL")
        #expect(card.region?.w == 0.36)
        #expect(card.isAnswered)
        // The word is on the card, and it is the word the SERVER chose — the
        // device composes nothing.
        #expect(card.name == "This is the cooler, silvery cast in it.")
    }

    /// A coarse card's OPTIONS each carry their own crop, and the two that are
    /// about the whole picture carry none.
    @Test func aCoarseCardCarriesAPerOptionCrop() throws {
        let json = """
        {"questionKey":"spark_focus","tier":"COARSE","attribute":null,
         "attributeValue":null,"name":null,"region":null,
         "optionRegions":[
          {"value":"the-color","label":"The color",
           "region":{"x":0.3,"y":0.5,"w":0.4,"h":0.4}},
          {"value":"the-shape","label":"The shape of it",
           "region":{"x":0.1,"y":0.2,"w":0.8,"h":0.6}},
          {"value":"the-whole-thing","label":"The whole thing","region":null},
          {"value":"not-sure","label":"Not sure","region":null}],
         "question":{"key":"spark_focus","label":"What made you stop scrolling?",
          "helpText":null,"kind":"SINGLE_SELECT","options":[
           {"value":"the-color","label":"The color"}],
          "minSelections":1,"maxSelections":1,"allowText":false},
         "selectedValues":[]}
        """
        let card = try JSONDecoder().decode(
            ConsultInspirationCard.self, from: Data(json.utf8)
        )
        #expect(card.tier == .coarse)
        #expect(card.name == nil)
        #expect(!card.isAnswered)
        let cropped = card.optionRegions.filter { $0.region != nil }
        #expect(cropped.map(\.value) == ["the-color", "the-shape"])
        // Different boxes: "the color" and "the shape of it" are two visibly
        // different parts of one photograph, which is what makes the question
        // answerable by someone never asked it before.
        #expect(cropped[0].region != cropped[1].region)
    }

    /// A build meeting a CARD it cannot parse renders the thread without it,
    /// rather than failing the whole read.
    @Test func aMalformedCardIsNilNotFatal() throws {
        let json = """
        {"kind":"INSPIRATION","id":"inspiration:x","author":"APP","state":"OPEN",
         "text":null,"sourceDecisionRequired":false,"source":null,"question":null,
         "card":{"questionKey":"x"},
         "answeredQuestionCount":0,"specificDetailCount":0,
         "requiredSpecificDetailCount":0,"schemaVersion":2}
        """
        let message = try JSONDecoder().decode(
            ConsultThreadMessage.self, from: Data(json.utf8)
        )
        #expect(message.kind == .inspiration)
        #expect(message.card == nil)
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

    /// The thread read is what the poll drives now, so a dropped poll is a
    /// dropped THREAD read.
    func setThreadErrorForTest(_ error: Error?) {
        threadError = error
    }

    func setInspirationImageErrorForTest(_ error: Error?) {
        inspirationImageError = error
    }
}
