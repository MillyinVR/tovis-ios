import Foundation

public protocol ConsultServicing: Sendable {
    func create(bookingId: String) async throws -> ConsultSession
    func agreements(consultId: String) async throws -> ConsultAgreementState
    func acceptAgreement(consultId: String, kind: ConsultAgreementKind,
                         agreementVersionId: String) async throws -> ConsultAgreementState
    func revokeAgreement(consultId: String, acceptanceId: String) async throws -> ConsultAgreementState
    func intake(consultId: String) async throws -> ConsultIntakeState
    func submitIntake(consultId: String, state: ConsultIntakeState, answers: [String: String],
                      idempotencyKey: String) async throws -> ConsultIntakeState
    func capture(consultId: String) async throws -> ConsultCaptureState
    func uploadAndCheckCapture(consultId: String, shot: ConsultCaptureShot,
                               pack: ConsultCaptureShotPack, jpegData: Data,
                               keys: ConsultCaptureMutationKeys) async throws -> ConsultCaptureQualityResponse
    func analysis(consultId: String) async throws -> ConsultAnalysisState
    func startAnalysis(consultId: String, idempotencyKey: String) async throws -> ConsultAnalysisState
    func results(consultId: String) async throws -> ConsultClientResults
    func recordLockedTeaserTap(consultId: String) async throws
}

public final class ConsultService: ConsultServicing, Sendable {
    public static let analysisSchemaVersion = 1
    public static let analysisPromptVersion = "hair-color-analysis-v1"
    public static let maximumPhotoBytes = 5_000_000

    private let api: APIClient
    private let uploadSession: URLSession
    private let supabaseURL: URL?
    private let supabaseKey: String?
    private let captureAttempts = ConsultCaptureAttemptStore()

    public init(api: APIClient, uploadSession: URLSession,
                supabaseURL: URL?, supabaseKey: String?) {
        self.api = api
        self.uploadSession = uploadSession
        self.supabaseURL = supabaseURL
        self.supabaseKey = supabaseKey
    }

    public func create(bookingId: String) async throws -> ConsultSession {
        struct Body: Encodable { let bookingId: String }
        let body = try JSONEncoder.canonical.encode(Body(bookingId: bookingId))
        let response: ConsultSessionResponse = try await api.request(
            "/client/consult", method: .post, body: body
        )
        return response.consult
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

    public func capture(consultId: String) async throws -> ConsultCaptureState {
        let response: ConsultCaptureStateResponse = try await api.request(
            "/client/consult/\(consultId)/capture"
        )
        return response.capture
    }

    public func uploadAndCheckCapture(
        consultId: String,
        shot: ConsultCaptureShot,
        pack: ConsultCaptureShotPack,
        jpegData: Data,
        keys: ConsultCaptureMutationKeys
    ) async throws -> ConsultCaptureQualityResponse {
        guard !jpegData.isEmpty else { throw ConsultClientFailure.invalidPhoto }
        guard jpegData.count <= Self.maximumPhotoBytes else { throw ConsultClientFailure.photoTooLarge }

        struct IssueBody: Encodable {
            let idempotencyKey: String
            let shotKey: ConsultCaptureShotKey
            let shotPackVersion: Int
            let schemaVersion: Int
            let contentType: String
            let sizeBytes: Int
        }
        let issueBody = try JSONEncoder.canonical.encode(IssueBody(
            idempotencyKey: keys.issue,
            shotKey: shot.key,
            shotPackVersion: pack.version,
            schemaVersion: pack.schemaVersion,
            contentType: "image/jpeg",
            sizeBytes: jpegData.count
        ))
        let issued: ConsultCaptureIssueUploadResponse
        if let prior = await captureAttempts.upload(for: keys.issue) {
            issued = prior
        } else {
            issued = try await api.request(
                "/client/consult/\(consultId)/capture/uploads", method: .post, body: issueBody
            )
            await captureAttempts.save(upload: issued, for: keys.issue)
        }
        guard issued.upload.shotKey == shot.key,
              issued.upload.shotPackVersion == pack.version,
              issued.upload.schemaVersion == pack.schemaVersion,
              issued.upload.contentType == "image/jpeg",
              issued.upload.maxBytes == jpegData.count,
              let signed = issued.upload.signedUrl.flatMap(URL.init(string:)) else {
            throw ConsultClientFailure.contractMismatch
        }

        if await !captureAttempts.didUpload(for: keys.issue) {
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
                await captureAttempts.markUploaded(for: keys.issue)
            } catch ConsultClientFailure.contractMismatch {
                throw ConsultClientFailure.contractMismatch
            } catch {
                // A lost upload response can still mean the private write landed.
                // Continue to attach: the server validates exact binding, media
                // type and byte count, and otherwise returns a stable failure.
            }
        }

        struct AttachBody: Encodable {
            let idempotencyKey: String
            let uploadSessionId: String
            let shotKey: ConsultCaptureShotKey
            let shotPackVersion: Int
            let schemaVersion: Int
        }
        let attachBody = try JSONEncoder.canonical.encode(AttachBody(
            idempotencyKey: keys.attach,
            uploadSessionId: issued.upload.uploadSessionId,
            shotKey: shot.key,
            shotPackVersion: pack.version,
            schemaVersion: pack.schemaVersion
        ))
        let captureId: String
        if let prior = await captureAttempts.captureId(for: keys.issue) {
            captureId = prior
        } else {
            let attached: ConsultCaptureAttachResponse = try await api.request(
                "/client/consult/\(consultId)/capture/attach", method: .post, body: attachBody
            )
            captureId = attached.captureId
            await captureAttempts.save(captureId: captureId, for: keys.issue)
        }

        struct QualityBody: Encodable {
            let idempotencyKey: String
            let shotPackVersion: Int
            let schemaVersion: Int
        }
        let qualityBody = try JSONEncoder.canonical.encode(QualityBody(
            idempotencyKey: keys.quality,
            shotPackVersion: pack.version,
            schemaVersion: pack.schemaVersion
        ))
        let response: ConsultCaptureQualityResponse = try await api.request(
            "/client/consult/\(consultId)/capture/\(captureId)/quality",
            method: .post,
            body: qualityBody
        )
        await captureAttempts.remove(keys.issue)
        return response
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

private actor ConsultCaptureAttemptStore {
    private struct Attempt {
        var upload: ConsultCaptureIssueUploadResponse
        var uploaded = false
        var captureId: String?
    }

    private var attempts: [String: Attempt] = [:]

    func upload(for key: String) -> ConsultCaptureIssueUploadResponse? { attempts[key]?.upload }
    func didUpload(for key: String) -> Bool { attempts[key]?.uploaded == true }
    func captureId(for key: String) -> String? { attempts[key]?.captureId }

    func save(upload: ConsultCaptureIssueUploadResponse, for key: String) {
        attempts[key] = Attempt(upload: upload)
    }

    func markUploaded(for key: String) { attempts[key]?.uploaded = true }
    func save(captureId: String, for key: String) { attempts[key]?.captureId = captureId }
    func remove(_ key: String) { attempts.removeValue(forKey: key) }
}
