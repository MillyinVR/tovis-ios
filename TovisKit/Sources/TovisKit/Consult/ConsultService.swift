import Foundation

public protocol ConsultServicing: Sendable {
    func availability(bookingId: String) async throws -> ConsultAvailability
    func create(bookingId: String) async throws -> ConsultSession
    // Book the Look, B8 — the look-anchored twin of the two above, plus the
    // booking proposal the flow ends on.
    func lookAvailability(lookPostId: String) async throws -> ConsultLookAvailability
    func createFromLook(lookPostId: String) async throws -> ConsultLookSession
    func proposal(consultId: String, locationType: String,
                  enhancementLineIds: [String]) async throws -> ConsultBookingProposalAvailability
    func agreements(consultId: String) async throws -> ConsultAgreementState
    func acceptAgreement(consultId: String, kind: ConsultAgreementKind,
                         agreementVersionId: String) async throws -> ConsultAgreementState
    func revokeAgreement(consultId: String, acceptanceId: String) async throws -> ConsultAgreementState
    func intake(consultId: String) async throws -> ConsultIntakeState
    func submitIntake(consultId: String, state: ConsultIntakeState, answers: [String: String],
                      idempotencyKey: String) async throws -> ConsultIntakeState
    func inspiration(consultId: String) async throws -> ConsultInspirationState
    func skipInspiration(consultId: String, schemaVersion: Int,
                         idempotencyKey: String) async throws -> ConsultInspirationState
    func uploadInspiration(consultId: String, schemaVersion: Int, jpegData: Data,
                           keys: ConsultInspirationMutationKeys) async throws -> ConsultInspirationState
    func answerInspiration(consultId: String, schemaVersion: Int, questionKey: String,
                           selectedValues: [String], text: String?,
                           sentiment: ConsultInspirationSentiment?,
                           idempotencyKey: String) async throws -> ConsultInspirationState
    func inspirationImage(consultId: String,
                          readEndpoint: String) async throws -> ConsultInspirationSignedRead
    func capture(consultId: String) async throws -> ConsultCaptureState
    // The capture chain is THREE separately-durable legs, not one call. Each is
    // driven by `ConsultCaptureUploadQueue`, which persists the bytes and all
    // three idempotency keys before the first one runs — so a leg that is
    // interrupted by a dismissed camera, a backgrounded app or a killed process
    // resumes at exactly the leg it stopped on, days later if it has to.
    // (The old single `uploadAndCheckCapture` held the ticket in RAM and did
    // its PUT on the foreground session; losing either lost the photo.)
    func issueCaptureUpload(consultId: String, shotKey: ConsultCaptureShotKey,
                            shotPackVersion: Int, schemaVersion: Int, sizeBytes: Int,
                            idempotencyKey: String) async throws -> ConsultCaptureUpload
    func attachCapture(consultId: String, uploadSessionId: String,
                       shotKey: ConsultCaptureShotKey, shotPackVersion: Int,
                       schemaVersion: Int,
                       idempotencyKey: String) async throws -> ConsultCaptureAttachResponse
    func checkCaptureQuality(consultId: String, captureId: String, shotPackVersion: Int,
                             schemaVersion: Int,
                             idempotencyKey: String) async throws -> ConsultCaptureQualityResponse
    func proceedWithAccepted(consultId: String) async throws -> ConsultCaptureState
    func setChartCopy(consultId: String, optIn: Bool) async throws -> ConsultCaptureState
    func analysis(consultId: String) async throws -> ConsultAnalysisState
    func startAnalysis(consultId: String, idempotencyKey: String) async throws -> ConsultAnalysisState
    func results(consultId: String) async throws -> ConsultClientResults
    func recordLockedTeaserTap(consultId: String) async throws
}

public final class ConsultService: ConsultServicing, Sendable {
    // Schema v3 / prompt v3 (2026-09-03, service-aware consult, tovis-app
    // slice 2): the analysis is told which service the consult is for and the
    // pro's menu; the colour lens became a service lens. The server refuses a
    // start that names an older pair, so these move with the server.
    public static let analysisSchemaVersion = 3
    public static let analysisPromptVersion = "service-analysis-v3"
    public static let maximumPhotoBytes = 5_000_000

    private let api: APIClient
    private let uploadSession: URLSession
    private let supabaseURL: URL?
    private let supabaseKey: String?

    public init(api: APIClient, uploadSession: URLSession,
                supabaseURL: URL?, supabaseKey: String?) {
        self.api = api
        self.uploadSession = uploadSession
        self.supabaseURL = supabaseURL
        self.supabaseKey = supabaseKey
    }

    public func availability(bookingId: String) async throws -> ConsultAvailability {
        let response: ConsultAvailabilityResponse = try await api.request(
            "/client/consult/availability",
            query: [URLQueryItem(name: "bookingId", value: bookingId)]
        )
        return response.availability
    }

    public func create(bookingId: String) async throws -> ConsultSession {
        struct Body: Encodable { let bookingId: String }
        let body = try JSONEncoder.canonical.encode(Body(bookingId: bookingId))
        let response: ConsultSessionResponse = try await api.request(
            "/client/consult", method: .post, body: body
        )
        return response.consult
    }

    // ── Book the Look, B8 ──────────────────────────────────────────────────
    //
    // 🔴 NONE OF THESE THREE ENDPOINTS EXIST IN PRODUCTION YET. B1–B7 are
    // merged and UNDEPLOYED, and a TestFlight build reaches a phone pointed at
    // prod long before the web deploys. Every caller therefore treats a throw
    // — a 404 most of all — as "no door", exactly as the consult gate did
    // (#375): the entry point simply does not render. Never a crash, never a
    // dead button, never a spinner that has nothing to wait for.

    /// GET /client/consult/look/availability — whether the consult door is open
    /// for this LOOK. The server owns the whole decision; the device shows an
    /// entry point only on an explicit `available: true`.
    public func lookAvailability(lookPostId: String) async throws -> ConsultLookAvailability {
        let response: ConsultLookAvailabilityResponse = try await api.request(
            "/client/consult/look/availability",
            query: [URLQueryItem(name: "lookPostId", value: lookPostId)]
        )
        return response.availability
    }

    /// POST /client/consult/look — create, or on a retry return, the
    /// consent-required consult shell anchored to a LOOK. Deliberately beside
    /// `create(bookingId:)` rather than inside it: the two anchors are separate
    /// types on the wire and the booking-anchored route must keep its shape.
    public func createFromLook(lookPostId: String) async throws -> ConsultLookSession {
        struct Body: Encodable { let lookPostId: String }
        let body = try JSONEncoder.canonical.encode(Body(lookPostId: lookPostId))
        let response: ConsultLookSessionResponse = try await api.request(
            "/client/consult/look", method: .post, body: body
        )
        return response.consult
    }

    /// GET /client/consult/{id}/proposal — "what would I be booking, and what
    /// does it start at?" for one consult, in one mode, with one set of
    /// enhancements ticked.
    ///
    /// 🔴 THE SERVER IS THE ANSWER. Both parameters name the QUESTION and
    /// reserve nothing, and every figure that comes back — the lines, the
    /// width, the "Starting at", each "+$40" — is derived from the pro's own
    /// menu by the same function the finalize will run. A caller must never sum
    /// the deltas itself; it re-asks with the new selection instead.
    ///
    /// `locationType` is REQUIRED with no default, for the same reason the
    /// route refuses to guess one: a salon price handed to someone who meant
    /// mobile is exactly what the mode reconciliation exists to prevent.
    ///
    /// An EMPTY `enhancementLineIds` means the floor alone, which is the
    /// default everywhere she has not chosen (decision 10, opt-in never
    /// pre-checked). Ids only — nothing the device can edit decides a price.
    public func proposal(
        consultId: String,
        locationType: String,
        enhancementLineIds: [String] = []
    ) async throws -> ConsultBookingProposalAvailability {
        var query = [URLQueryItem(name: "locationType", value: locationType)]
        // Comma-separated, like every other id list this API puts in a query
        // string. Sent in the caller's order, which is always the SERVER's own
        // order (`ConsultBookingProposal.selectedEnhancementLineIds`).
        if !enhancementLineIds.isEmpty {
            query.append(URLQueryItem(
                name: "enhancementIds",
                value: enhancementLineIds.joined(separator: ",")
            ))
        }
        let response: ConsultBookingProposalResponse = try await api.request(
            "/client/consult/\(consultId)/proposal", query: query
        )
        return response.proposal
    }

    public func agreements(consultId: String) async throws -> ConsultAgreementState {
        let response: ConsultAgreementStateResponse = try await api.request(
            "/client/consult/\(consultId)/agreements"
        )
        return response.agreementState
    }

    public func acceptAgreement(consultId: String, kind: ConsultAgreementKind,
                                agreementVersionId: String) async throws -> ConsultAgreementState {
        struct Body: Encodable { let kind: ConsultAgreementKind; let agreementVersionId: String }
        let body = try JSONEncoder.canonical.encode(
            Body(kind: kind, agreementVersionId: agreementVersionId)
        )
        let response: ConsultAgreementAcceptResponse = try await api.request(
            "/client/consult/\(consultId)/agreements/accept", method: .post, body: body
        )
        return response.agreementState
    }

    public func revokeAgreement(consultId: String,
                                acceptanceId: String) async throws -> ConsultAgreementState {
        struct Body: Encodable { let acceptanceId: String; let reason: String }
        let body = try JSONEncoder.canonical.encode(Body(
            acceptanceId: acceptanceId,
            reason: "Client withdrew consent in the iOS consult flow."
        ))
        let response: ConsultAgreementStateResponse = try await api.request(
            "/client/consult/\(consultId)/agreements/revoke", method: .post, body: body
        )
        return response.agreementState
    }

    public func intake(consultId: String) async throws -> ConsultIntakeState {
        let response: ConsultIntakeStateResponse = try await api.request(
            "/client/consult/\(consultId)/intake"
        )
        return response.intake
    }

    public func submitIntake(consultId: String, state: ConsultIntakeState,
                             answers: [String: String], idempotencyKey: String) async throws
        -> ConsultIntakeState {
        struct Body: Encodable {
            let idempotencyKey: String
            let packVersion: Int
            let schemaVersion: Int
            let complete: Bool
            let answers: [String: String]
        }
        let body = try JSONEncoder.canonical.encode(Body(
            idempotencyKey: idempotencyKey,
            packVersion: state.questionPack.version,
            schemaVersion: state.questionPack.schemaVersion,
            complete: true,
            answers: answers
        ))
        let response: ConsultIntakeSubmitResponse = try await api.request(
            "/client/consult/\(consultId)/intake", method: .post, body: body
        )
        return response.intake
    }

    public func inspiration(consultId: String) async throws -> ConsultInspirationState {
        let response: ConsultInspirationStateResponse = try await api.request(
            "/client/consult/\(consultId)/inspiration"
        )
        return response.inspiration
    }

    public func skipInspiration(consultId: String, schemaVersion: Int,
                                idempotencyKey: String) async throws -> ConsultInspirationState {
        struct Body: Encodable {
            let idempotencyKey: String
            let source: String
            let schemaVersion: Int
        }
        let body = try JSONEncoder.canonical.encode(Body(
            idempotencyKey: idempotencyKey,
            source: "NONE",
            schemaVersion: schemaVersion
        ))
        let response: ConsultInspirationMutationResponse = try await api.request(
            "/client/consult/\(consultId)/inspiration", method: .post, body: body
        )
        return response.inspiration
    }

    public func uploadInspiration(
        consultId: String,
        schemaVersion: Int,
        jpegData: Data,
        keys: ConsultInspirationMutationKeys
    ) async throws -> ConsultInspirationState {
        guard !jpegData.isEmpty else { throw ConsultClientFailure.invalidPhoto }
        guard jpegData.count <= Self.maximumPhotoBytes else { throw ConsultClientFailure.photoTooLarge }

        struct IssueBody: Encodable {
            let idempotencyKey: String
            let schemaVersion: Int
            let contentType: String
            let sizeBytes: Int
        }
        let issueBody = try JSONEncoder.canonical.encode(IssueBody(
            idempotencyKey: keys.issue,
            schemaVersion: schemaVersion,
            contentType: "image/jpeg",
            sizeBytes: jpegData.count
        ))
        let issued: ConsultInspirationIssueUploadResponse = try await api.request(
            "/client/consult/\(consultId)/inspiration/uploads", method: .post, body: issueBody
        )
        guard issued.upload.schemaVersion == schemaVersion,
              issued.upload.contentType == "image/jpeg",
              issued.upload.maxBytes == jpegData.count,
              let signed = issued.upload.signedUrl.flatMap(URL.init(string:)) else {
            throw ConsultClientFailure.contractMismatch
        }

        do {
            try await SupabaseSignedUpload.putSignedURL(
                session: uploadSession,
                supabaseURL: supabaseURL,
                supabaseKey: supabaseKey,
                signedURL: signed,
                expectedToken: issued.upload.token,
                data: jpegData,
                contentType: "image/jpeg"
            )
        } catch ConsultClientFailure.contractMismatch {
            throw ConsultClientFailure.contractMismatch
        } catch {
            // A lost upload response can still mean the private write landed —
            // continue to attach, same as capture: the server validates media
            // type and byte count and otherwise returns a stable failure.
        }

        struct AttachBody: Encodable {
            let idempotencyKey: String
            let inspirationId: String
            let schemaVersion: Int
        }
        let attachBody = try JSONEncoder.canonical.encode(AttachBody(
            idempotencyKey: keys.attach,
            inspirationId: issued.upload.inspirationId,
            schemaVersion: schemaVersion
        ))
        let attached: ConsultInspirationMutationResponse = try await api.request(
            "/client/consult/\(consultId)/inspiration/attach", method: .post, body: attachBody
        )
        return attached.inspiration
    }

    public func answerInspiration(
        consultId: String,
        schemaVersion: Int,
        questionKey: String,
        selectedValues: [String],
        text: String?,
        sentiment: ConsultInspirationSentiment?,
        idempotencyKey: String
    ) async throws -> ConsultInspirationState {
        struct Body: Encodable {
            let idempotencyKey: String
            let schemaVersion: Int
            let questionKey: String
            let selectedValues: [String]
            let text: String?
            let sentiment: ConsultInspirationSentiment?

            enum CodingKeys: String, CodingKey {
                case idempotencyKey, schemaVersion, questionKey, selectedValues, text, sentiment
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(idempotencyKey, forKey: .idempotencyKey)
                try container.encode(schemaVersion, forKey: .schemaVersion)
                try container.encode(questionKey, forKey: .questionKey)
                try container.encode(selectedValues, forKey: .selectedValues)
                // The server requires text and sentiment together or not at
                // all — omit the keys entirely rather than sending null.
                try container.encodeIfPresent(text, forKey: .text)
                try container.encodeIfPresent(sentiment, forKey: .sentiment)
            }
        }
        let body = try JSONEncoder.canonical.encode(Body(
            idempotencyKey: idempotencyKey,
            schemaVersion: schemaVersion,
            questionKey: questionKey,
            selectedValues: selectedValues,
            text: text,
            sentiment: sentiment
        ))
        let response: ConsultInspirationMutationResponse = try await api.request(
            "/client/consult/\(consultId)/inspiration/answers", method: .post, body: body
        )
        return response.inspiration
    }

    /// The inspiration photo's short-lived read URL.
    ///
    /// `imageReadEndpoint` may only ever name a route that answers
    /// `ConsultInspirationSignedRead` — `{ url, expiresInSeconds }` — and since
    /// the server now serves ONE such route per consult for every source
    /// (uploads and the anchoring Look alike), the only endpoint this client
    /// will follow is that one. The guard stays strict on purpose: a path that
    /// arrives in a state DTO is server-supplied input, and following an
    /// arbitrary one would let a changed server steer the app at any URL it
    /// liked.
    ///
    /// 🔴 A refusal here THROWS. It used to be swallowed into `nil` by the
    /// caller, which is what made a look-anchored consult (whose endpoint was
    /// then `/api/v1/looks/{id}`) ask "what did you like about it?" with an
    /// empty panel and no error anywhere — handoff Part 1, B4.
    public func inspirationImage(consultId: String,
                                 readEndpoint: String) async throws -> ConsultInspirationSignedRead {
        // The state DTO serves the endpoint as a full server path; APIClient
        // already prefixes /api/v1, so strip it.
        let expected = "/api/v1/client/consult/\(consultId)/inspiration/media"
        guard readEndpoint == expected else { throw ConsultClientFailure.contractMismatch }
        let read: ConsultInspirationSignedRead =
            try await api.request("/client/consult/\(consultId)/inspiration/media")
        // A route that answers the right shape with an unusable payload is the
        // same failure as the wrong route: refuse it rather than hand the view
        // a URL it cannot load or an expiry it cannot schedule from.
        guard !read.url.isEmpty,
              read.expiresInSeconds.isFinite,
              read.expiresInSeconds > 0 else {
            throw ConsultClientFailure.contractMismatch
        }
        return read
    }

    public func capture(consultId: String) async throws -> ConsultCaptureState {
        let response: ConsultCaptureStateResponse = try await api.request(
            "/client/consult/\(consultId)/capture"
        )
        return response.capture
    }

    public func proceedWithAccepted(consultId: String) async throws -> ConsultCaptureState {
        let response: ConsultCaptureStateResponse = try await api.request(
            "/client/consult/\(consultId)/capture/proceed",
            method: .post,
            body: Data("{}".utf8)
        )
        return response.capture
    }

    public func setChartCopy(consultId: String, optIn: Bool) async throws -> ConsultCaptureState {
        struct Body: Encodable { let optIn: Bool }
        let body = try JSONEncoder.canonical.encode(Body(optIn: optIn))
        let response: ConsultCaptureStateResponse = try await api.request(
            "/client/consult/\(consultId)/capture/chart-copy", method: .post, body: body
        )
        return response.capture
    }

    /// Leg 1 — mint (or replay) the upload ticket for one shot.
    ///
    /// Replaying the same `idempotencyKey` returns the SAME `uploadSessionId`
    /// and storage path with a FRESH signed URL, which is exactly what a queue
    /// resuming after a dead connection needs. It throws
    /// `CONSULT_CAPTURE_UPLOAD_EXPIRED` (410) once that upload session is no
    /// longer PENDING or has passed its one-hour TTL — see
    /// `issueConsultCaptureUpload` in lib/consult/captureContract.ts.
    ///
    /// The server hashes `sizeBytes` into the request hash, so a replay MUST
    /// present the identical bytes. That is why the queue persists the JPEG
    /// rather than re-encoding it.
    public func issueCaptureUpload(
        consultId: String,
        shotKey: ConsultCaptureShotKey,
        shotPackVersion: Int,
        schemaVersion: Int,
        sizeBytes: Int,
        idempotencyKey: String
    ) async throws -> ConsultCaptureUpload {
        guard sizeBytes > 0 else { throw ConsultClientFailure.invalidPhoto }
        guard sizeBytes <= Self.maximumPhotoBytes else { throw ConsultClientFailure.photoTooLarge }

        struct IssueBody: Encodable {
            let idempotencyKey: String
            let shotKey: ConsultCaptureShotKey
            let shotPackVersion: Int
            let schemaVersion: Int
            let contentType: String
            let sizeBytes: Int
        }
        let body = try JSONEncoder.canonical.encode(IssueBody(
            idempotencyKey: idempotencyKey,
            shotKey: shotKey,
            shotPackVersion: shotPackVersion,
            schemaVersion: schemaVersion,
            contentType: "image/jpeg",
            sizeBytes: sizeBytes
        ))
        let issued: ConsultCaptureIssueUploadResponse = try await api.request(
            "/client/consult/\(consultId)/capture/uploads", method: .post, body: body
        )
        // The ticket must describe the photo we are actually holding. A ticket
        // bound to another slot, pack or size is not a bad connection — it is a
        // contract the app must refuse rather than upload into.
        guard issued.upload.shotKey == shotKey,
              issued.upload.shotPackVersion == shotPackVersion,
              issued.upload.schemaVersion == schemaVersion,
              issued.upload.contentType == "image/jpeg",
              issued.upload.maxBytes == sizeBytes,
              issued.upload.signedUrl.flatMap(URL.init(string:)) != nil else {
            throw ConsultClientFailure.contractMismatch
        }
        return issued.upload
    }

    /// Leg 3 — bind the uploaded object to a `ConsultCapture` row.
    ///
    /// Idempotent on `attachIdempotencyKey`: a replay returns the SAME
    /// `captureId`, which is how the queue recovers a capture whose attach
    /// response was lost (offline the instant it landed, or the process died).
    /// Attach is also what CONSUMES the upload session, so it is always tried
    /// before any thought of re-issuing.
    public func attachCapture(
        consultId: String,
        uploadSessionId: String,
        shotKey: ConsultCaptureShotKey,
        shotPackVersion: Int,
        schemaVersion: Int,
        idempotencyKey: String
    ) async throws -> ConsultCaptureAttachResponse {
        struct AttachBody: Encodable {
            let idempotencyKey: String
            let uploadSessionId: String
            let shotKey: ConsultCaptureShotKey
            let shotPackVersion: Int
            let schemaVersion: Int
        }
        let body = try JSONEncoder.canonical.encode(AttachBody(
            idempotencyKey: idempotencyKey,
            uploadSessionId: uploadSessionId,
            shotKey: shotKey,
            shotPackVersion: shotPackVersion,
            schemaVersion: schemaVersion
        ))
        return try await api.request(
            "/client/consult/\(consultId)/capture/attach", method: .post, body: body
        )
    }

    /// Leg 4 — the paid quality verdict. Idempotent on its own key, and the
    /// server also short-circuits any capture that already has a verdict, so a
    /// replayed check never spends a second provider call.
    public func checkCaptureQuality(
        consultId: String,
        captureId: String,
        shotPackVersion: Int,
        schemaVersion: Int,
        idempotencyKey: String
    ) async throws -> ConsultCaptureQualityResponse {
        struct QualityBody: Encodable {
            let idempotencyKey: String
            let shotPackVersion: Int
            let schemaVersion: Int
        }
        let body = try JSONEncoder.canonical.encode(QualityBody(
            idempotencyKey: idempotencyKey,
            shotPackVersion: shotPackVersion,
            schemaVersion: schemaVersion
        ))
        return try await api.request(
            "/client/consult/\(consultId)/capture/\(captureId)/quality",
            method: .post,
            body: body
        )
    }

    public func analysis(consultId: String) async throws -> ConsultAnalysisState {
        let response: ConsultAnalysisStateResponse = try await api.request(
            "/client/consult/\(consultId)/analysis"
        )
        return response.analysis
    }

    public func startAnalysis(consultId: String,
                              idempotencyKey: String) async throws -> ConsultAnalysisState {
        struct Body: Encodable {
            let idempotencyKey: String
            let schemaVersion: Int
            let promptVersion: String
        }
        let body = try JSONEncoder.canonical.encode(Body(
            idempotencyKey: idempotencyKey,
            schemaVersion: Self.analysisSchemaVersion,
            promptVersion: Self.analysisPromptVersion
        ))
        let response: ConsultAnalysisStartResponse = try await api.request(
            "/client/consult/\(consultId)/analysis", method: .post, body: body
        )
        return response.analysis
    }

    public func results(consultId: String) async throws -> ConsultClientResults {
        let response: ConsultClientResultsResponse = try await api.request(
            "/client/consult/\(consultId)/results"
        )
        guard response.results.hasFaithfulClientContract else {
            throw ConsultClientFailure.contractMismatch
        }
        return response.results
    }

    public func recordLockedTeaserTap(consultId: String) async throws {
        let response: ConsultTeaserTapResponse = try await api.request(
            "/client/consult/\(consultId)/results/teaser-tap",
            method: .post,
            body: Data("{}".utf8)
        )
        guard response.teaser.locked, response.teaser.tapped else {
            throw ConsultClientFailure.contractMismatch
        }
    }
}

