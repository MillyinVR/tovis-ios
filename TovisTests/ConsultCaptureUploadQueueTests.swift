import Foundation
import Testing
import TovisKit
@testable import Tovis

// The durable consult capture queue (P2d).
//
// These pin the properties the prod failure actually needed and did not have:
// the chain resumes at the right leg in a process that never started it, a
// resumed chain never mints a second upload session or spends a second paid
// quality check, a refusal parks instead of spinning, and — the one every naive
// implementation gets wrong — the 429 photo-check cap is TERMINAL even though
// `APIError.isRetryable` calls a 429 transient.
//
// The transfer is substituted so a "round trip" completes inline. Everything
// else is the shipping code: the same vault, the same leg ordering, the same
// error classification.

/// Shared by these tests and `ConsultFlowViewModelTests`, so there is one
/// definition of "a queue wired to a mock" rather than two that can drift.
@MainActor
enum ConsultCaptureUploadQueueTestSupport {
    /// Run `body` against a vault directory nobody else can see. Every test that
    /// writes owed photos must go through this — suites run in parallel, and a
    /// shared vault means one suite's queue drains another suite's items.
    static func isolated(_ name: String, _ body: () async throws -> Void) async rethrows {
        try await ConsultCaptureVaultIsolation.$suffix.withValue(
            "test-\(name)-\(UUID().uuidString)"
        ) {
            defer { purgeVault() }
            try await body()
        }
    }

    /// ⚠️ `async`, and it awaits the queue's OWN first drain before returning.
    ///
    /// `configure` schedules a drain — that is how a relaunch picks up work from
    /// a previous process — and that drain runs whenever the runtime gets to it,
    /// which can be after the test has written its item. Leaving it pending gave
    /// the queue TWO passes over the same shot, so a leg that failed transiently
    /// in the first pass quietly succeeded in the second and the test saw a
    /// settled queue instead of a stalled one. Draining it out here, against an
    /// empty vault, makes each test's passes exactly the ones it asked for.
    static func freshQueue(
        service: any ConsultServicing,
        transfer: ConsultCaptureUploadQueue.Transfer? = nil
    ) async -> ConsultCaptureUploadQueue {
        let queue = ConsultCaptureUploadQueue()
        queue.configure(
            dependencies: .init(
                service: service,
                supabaseURL: URL(string: "https://storage.test"),
                supabaseKey: "publishable-test-key"
            ),
            transfer: transfer ?? { _, _, _ in .completed(status: 200, error: nil) }
        )
        await queue.settle()
        return queue
    }

    /// Release everything in the CURRENT isolation's vault.
    static func purgeVault() {
        for item in SessionByteVault.allConsultCaptures() {
            SessionByteVault.removeConsultCapture(item.id)
        }
    }
}

@Suite(.serialized)
@MainActor
struct ConsultCaptureUploadQueueTests {
    private typealias Support = ConsultCaptureUploadQueueTestSupport
    private static let consultId = "consult_queue_tests"

    /// A stub that records every leg and can be told to fail on demand.
    private final class StubService: ConsultServicing, @unchecked Sendable {
        var issuedKeys: [String] = []
        var attachedKeys: [String] = []
        var qualityKeys: [String] = []
        var issueErrors: [Error] = []
        var attachErrors: [Error] = []
        var qualityErrors: [Error] = []
        var accepted = true
        /// Server behaviour that matters: the same issue key means the same
        /// upload session, and the same attach key means the same capture.
        private var sessionsByIssueKey: [String: String] = [:]
        private var capturesByAttachKey: [String: String] = [:]
        private var tokenSerial = 0

        func issueCaptureUpload(
            consultId: String, shotKey: ConsultCaptureShotKey, shotPackVersion: Int,
            schemaVersion: Int, sizeBytes: Int, idempotencyKey: String
        ) async throws -> ConsultCaptureUpload {
            issuedKeys.append(idempotencyKey)
            if !issueErrors.isEmpty { throw issueErrors.removeFirst() }
            let session = sessionsByIssueKey[idempotencyKey]
                ?? "upload_\(sessionsByIssueKey.count + 1)"
            sessionsByIssueKey[idempotencyKey] = session
            tokenSerial += 1
            let token = "tok\(tokenSerial)"
            return try Self.decode(ConsultCaptureUpload.self, [
                "uploadSessionId": session, "shotKey": shotKey.rawValue,
                "shotPackVersion": shotPackVersion, "schemaVersion": schemaVersion,
                "contentType": "image/jpeg", "maxBytes": sizeBytes,
                "expiresAt": "2026-08-11T19:00:00.000Z",
                "rawExpiresAt": "2026-08-12T18:00:00.000Z", "token": token,
                "signedUrl": "https://storage.test/storage/v1/object/upload/sign/media-private/consult-raw/v1/\(session).jpg?token=\(token)",
            ])
        }

        func attachCapture(
            consultId: String, uploadSessionId: String, shotKey: ConsultCaptureShotKey,
            shotPackVersion: Int, schemaVersion: Int, idempotencyKey: String
        ) async throws -> ConsultCaptureAttachResponse {
            attachedKeys.append(idempotencyKey)
            if !attachErrors.isEmpty { throw attachErrors.removeFirst() }
            let captureId = capturesByAttachKey[idempotencyKey]
                ?? "capture_\(capturesByAttachKey.count + 1)"
            capturesByAttachKey[idempotencyKey] = captureId
            return try Self.decode(ConsultCaptureAttachResponse.self, [
                "capture": Self.captureState, "captureId": captureId, "replayed": false,
            ])
        }

        func checkCaptureQuality(
            consultId: String, captureId: String, shotPackVersion: Int,
            schemaVersion: Int, idempotencyKey: String
        ) async throws -> ConsultCaptureQualityResponse {
            qualityKeys.append(idempotencyKey)
            if !qualityErrors.isEmpty { throw qualityErrors.removeFirst() }
            return try Self.decode(ConsultCaptureQualityResponse.self, [
                "quality": [
                    "captureId": captureId, "accepted": accepted,
                    "reasonCode": accepted ? "PASS" : "BLURRY",
                    "retakeTip": NSNull(), "checkedAt": "2026-08-11T18:10:00.000Z",
                ],
                "capture": Self.captureState, "replayed": false,
            ])
        }

        private static func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
            try JSONDecoder().decode(
                type, from: JSONSerialization.data(withJSONObject: value)
            )
        }

        private static let captureState: [String: Any] = [
            // Spelled out rather than read off the enclosing suite: a nonisolated
            // stub may not touch a main-actor static (a hard error in Swift 6).
            "consultId": "consult_queue_tests", "status": "MEDIA_READY",
            "shotPack": [
                "id": "hair_v2", "categorySlug": "hair-color", "version": 2,
                "schemaVersion": 1,
                "shots": [[
                    "key": "hair_back", "title": "Back", "instruction": "Turn around",
                    "requirement": "REQUIRED",
                ]],
            ],
            "slots": [], "chartCopy": ["optIn": true, "decidedAt": NSNull()],
        ]

        // Unused legs — this stub exists for the capture chain only.
        func availability(bookingId: String) async throws -> ConsultAvailability { fail() }
        func create(bookingId: String) async throws -> ConsultSession { fail() }
        func lookAvailability(lookPostId: String) async throws -> ConsultLookAvailability { fail() }
        func createFromLook(lookPostId: String) async throws -> ConsultLookSession { fail() }
        func proposal(consultId: String, locationType: String,
                      enhancementLineIds: [String]) async throws -> ConsultBookingProposalAvailability { fail() }
        func agreements(consultId: String) async throws -> ConsultAgreementState { fail() }
        func acceptAgreement(consultId: String, kind: ConsultAgreementKind,
                             agreementVersionId: String) async throws -> ConsultAgreementState { fail() }
        func revokeAgreement(consultId: String, acceptanceId: String) async throws -> ConsultAgreementState { fail() }
        func intake(consultId: String) async throws -> ConsultIntakeState { fail() }
        func submitIntake(consultId: String, state: ConsultIntakeState, answers: [String: String],
                          idempotencyKey: String) async throws -> ConsultIntakeState { fail() }
        func inspiration(consultId: String) async throws -> ConsultInspirationState { fail() }
        func skipInspiration(consultId: String, schemaVersion: Int,
                             idempotencyKey: String) async throws -> ConsultInspirationState { fail() }
        func uploadInspiration(consultId: String, schemaVersion: Int, jpegData: Data,
                               keys: ConsultInspirationMutationKeys) async throws -> ConsultInspirationState { fail() }
        func answerInspiration(consultId: String, schemaVersion: Int, questionKey: String,
                               selectedValues: [String], text: String?,
                               sentiment: ConsultInspirationSentiment?,
                               idempotencyKey: String) async throws -> ConsultInspirationState { fail() }
        func inspirationImage(consultId: String,
                              readEndpoint: String) async throws -> ConsultInspirationSignedRead { fail() }
        func capture(consultId: String) async throws -> ConsultCaptureState {
            try Self.decode(ConsultCaptureState.self, Self.captureState)
        }
        func proceedWithAccepted(consultId: String) async throws -> ConsultCaptureState { fail() }
        func setChartCopy(consultId: String, optIn: Bool) async throws -> ConsultCaptureState { fail() }
        func analysis(consultId: String) async throws -> ConsultAnalysisState { fail() }
        func startAnalysis(consultId: String, idempotencyKey: String) async throws -> ConsultAnalysisState { fail() }
        func results(consultId: String) async throws -> ConsultClientResults { fail() }
        func recordLockedTeaserTap(consultId: String) async throws { fail() }

        private func fail() -> Never {
            fatalError("ConsultCaptureUploadQueueTests stub: leg not used by these tests")
        }
    }

    private func write(shot: ConsultCaptureShotKey = .hairBack)
        -> SessionByteVault.ConsultCaptureItem? {
        SessionByteVault.writeConsultCapture(
            Data("bytes".utf8), consultId: Self.consultId, shotKey: shot,
            shotPackVersion: 2, schemaVersion: 1, capturedAt: Date()
        )
    }

    private func serverError(_ status: Int, _ code: String) -> APIError {
        .server(status: status, message: "refused", code: code)
    }

    // MARK: - The happy path

    @Test func aShotRunsAllFourLegsAndThenReleasesItsBytes() async throws {
        try await Support.isolated("all-legs") {
            let service = StubService()
            let queue = await Support.freshQueue(service: service)
            let item = try #require(write())
            queue.enqueue(item)
            await queue.settle()

            #expect(service.issuedKeys == [item.keys.issue])
            #expect(service.attachedKeys == [item.keys.attach])
            #expect(service.qualityKeys == [item.keys.quality])
            #expect(queue.items(consultId: Self.consultId).isEmpty)
            #expect(SessionByteVault.consultCaptureBytes(item.id) == nil)
        }
    }

    // MARK: - The prod failure, directly

    /// 🔴 The one that matters. Bytes are written and the process "dies" before
    /// any leg runs — no in-memory state at all — and a NEW queue picks the shot
    /// up from disk and finishes it. This is what the old chain could not do.
    @Test func aBrandNewQueuePicksUpAShotItNeverSaw() async throws {
        try await Support.isolated("cold-pickup") {
            let service = StubService()
            // Process 1: the shutter fires and nothing else happens.
            let item = try #require(write())

            // Process 2: a queue that has never seen this shot.
            let queue = ConsultCaptureUploadQueue()
            queue.configure(
                dependencies: .init(
                    service: service,
                    supabaseURL: URL(string: "https://storage.test"),
                    supabaseKey: "publishable-test-key"
                ),
                transfer: { _, _, _ in .completed(status: 200, error: nil) }
            )
            await queue.settle()

            #expect(service.qualityKeys == [item.keys.quality])
            #expect(queue.items(consultId: Self.consultId).isEmpty)
        }
    }

    /// A chain interrupted after the bytes landed resumes at ATTACH — it does
    /// not re-issue. Attach is what consumes the upload session, so re-issuing
    /// first would hit a consumed one and read as an expiry; and a rotated key
    /// would mint a second upload session for one photograph.
    @Test func aChainInterruptedAfterTheUploadResumesAtAttach() async throws {
        try await Support.isolated("resume-attach") {
            let service = StubService()
            let queue = await Support.freshQueue(service: service)
            var item = try #require(write())
            item.uploadSessionId = "upload_from_a_dead_process"
            item.storagePath = "consult-raw/v1/opaque.jpg"
            item.bytesUploaded = true
            #expect(SessionByteVault.saveConsultCapture(item))

            await queue.drain()

            #expect(service.issuedKeys.isEmpty)
            #expect(service.attachedKeys == [item.keys.attach])
            #expect(service.qualityKeys == [item.keys.quality])
        }
    }

    /// A chain interrupted after ATTACH resumes at the quality check, under the
    /// SAME key — the server short-circuits it, so a resumed shot never spends a
    /// second paid provider call.
    @Test func aChainInterruptedAfterAttachResumesAtTheQualityCheck() async throws {
        try await Support.isolated("resume-quality") {
            let service = StubService()
            let queue = await Support.freshQueue(service: service)
            var item = try #require(write())
            item.uploadSessionId = "upload_x"
            item.bytesUploaded = true
            item.captureId = "capture_from_a_dead_process"
            #expect(SessionByteVault.saveConsultCapture(item))

            await queue.drain()

            #expect(service.issuedKeys.isEmpty)
            #expect(service.attachedKeys.isEmpty)
            #expect(service.qualityKeys == [item.keys.quality])
        }
    }

    // MARK: - Failure classification

    /// A transient failure keeps the shot, keeps its keys, and reports a stall —
    /// it does not park the photograph and it does not rotate anything.
    @Test func aTransientFailureHoldsTheShotAndItsKeys() async throws {
        try await Support.isolated("transient") {
            let service = StubService()
            service.attachErrors = [serverError(503, "CONSULT_CAPTURE_STORAGE_UNAVAILABLE")]
            let queue = await Support.freshQueue(service: service)
            let item = try #require(write())
            queue.enqueue(item)
            await queue.settle()

            let owed = try #require(queue.items(consultId: Self.consultId).first)
            #expect(owed.keys == item.keys)
            #expect(!owed.isBlocked)
            #expect(queue.stalled)
            #expect(service.qualityKeys.isEmpty)
        }
    }

    /// 🔴 The photo-check cap is served as a **429**, and `APIError.isRetryable`
    /// says a 429 is transient. It is not: it is a hard per-consult limit, and a
    /// queue that believed the general rule would retry until the raw TTL ran
    /// out. The shot is parked for a decision instead — with its bytes kept,
    /// because a refusal makes this the only copy that exists.
    @Test func theQualityCheckCapIsTerminalDespiteBeingA429() async throws {
        try await Support.isolated("quality-cap") {
            let service = StubService()
            service.qualityErrors = [serverError(429, "CONSULT_CAPTURE_QUALITY_LIMIT_EXCEEDED")]
            let queue = await Support.freshQueue(service: service)
            let item = try #require(write())
            queue.enqueue(item)
            await queue.settle()

            let owed = try #require(queue.items(consultId: Self.consultId).first)
            #expect(owed.isBlocked)
            #expect(queue.stage(consultId: Self.consultId, shotKey: .hairBack) == .blocked)
            #expect(service.qualityKeys.count == 1)
            #expect(SessionByteVault.consultCaptureBytes(item.id) != nil)
        }
    }

    /// An expired ticket is not a lost photograph. The bytes are still on disk,
    /// so the keys rotate and the chain starts over on a clean upload session.
    @Test func anExpiredTicketRotatesTheKeysAndStartsOver() async throws {
        try await Support.isolated("expired-ticket") {
            let service = StubService()
            service.issueErrors = [serverError(410, "CONSULT_CAPTURE_UPLOAD_EXPIRED")]
            let queue = await Support.freshQueue(service: service)
            let item = try #require(write())
            queue.enqueue(item)
            await queue.settle()

            // Two issue attempts: the expired one, then a fresh key that worked.
            #expect(service.issuedKeys.count == 2)
            #expect(service.issuedKeys.first == item.keys.issue)
            #expect(service.issuedKeys.last != item.keys.issue)
            #expect(service.qualityKeys.count == 1)
            #expect(queue.items(consultId: Self.consultId).isEmpty)
        }
    }

    /// A transfer that came back with an HTTP status REACHED storage, so the
    /// next move is attach — never a second PUT, which `x-upsert: false` would
    /// refuse forever.
    @Test func aNon2xxTransferGoesToAttachRatherThanUploadingAgain() async throws {
        try await Support.isolated("non-2xx") {
            let service = StubService()
            nonisolated(unsafe) var transfers = 0
            let queue = await Support.freshQueue(service: service) { _, _, _ in
                transfers += 1
                return .completed(status: 409, error: nil)
            }
            let item = try #require(write())
            queue.enqueue(item)
            await queue.settle()

            #expect(transfers == 1)
            #expect(service.attachedKeys == [item.keys.attach])
            #expect(service.qualityKeys == [item.keys.quality])
        }
    }

    /// A transfer that never reached storage at all keeps the bytes unsent, so
    /// the same bytes go again under the same key when the connection returns.
    @Test func aTransportFailureLeavesTheBytesUnsent() async throws {
        try await Support.isolated("transport") {
            let service = StubService()
            let queue = await Support.freshQueue(service: service) { _, _, _ in
                .completed(status: nil, error: URLError(.notConnectedToInternet))
            }
            let item = try #require(write())
            queue.enqueue(item)
            await queue.settle()

            let owed = try #require(queue.items(consultId: Self.consultId).first)
            #expect(!owed.bytesUploaded)
            #expect(owed.keys == item.keys)
            #expect(service.attachedKeys.isEmpty)
            #expect(queue.stalled)
        }
    }

    // MARK: - Consent

    /// Revoking consent purges the client's photographs from this device too.
    @Test func discardingAConsultReleasesEveryShotItOwes() async throws {
        try await Support.isolated("discard") {
            let service = StubService()
            service.issueErrors = [serverError(503, "CONSULT_CAPTURE_STORAGE_UNAVAILABLE")]
            let queue = await Support.freshQueue(service: service)
            let item = try #require(write())
            queue.enqueue(item)
            await queue.settle()
            #expect(!queue.items(consultId: Self.consultId).isEmpty)

            queue.discardAll(consultId: Self.consultId)
            #expect(queue.items(consultId: Self.consultId).isEmpty)
            #expect(SessionByteVault.consultCaptureBytes(item.id) == nil)
        }
    }
}
