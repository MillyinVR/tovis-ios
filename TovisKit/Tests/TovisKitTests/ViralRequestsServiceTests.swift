import Foundation
import Testing
@testable import TovisKit

// POST /api/v1/viral-service-requests — the write half of the Viral Looks band.
//
// Every envelope below is a VERBATIM capture from the running route (local
// server, minted CLIENT jwt, 2026-07-18), not a shape invented to match the
// decoder — a test that mocks the shape the code assumes proves nothing about
// the wire.
//
// Pinned from that drive:
//   • 201 → {"ok":true,"request":{ …the full row… }}, status "REQUESTED".
//   • the handler genuinely READS the body (unlike the comment-report route):
//     a blank name is 400 "Viral request name is required.", a malformed
//     sourceUrl is 400 "sourceUrl must be a valid URL.", a non-http scheme is
//     400 "sourceUrl must use http or https.", >160 chars is its own 400, and a
//     junk body with no name still 400s rather than silently succeeding.
//   • NO idempotency and NO rate limit: the same body with an identical
//     Idempotency-Key created TWO rows, and eight rapid POSTs all returned 201.
//     The client owns the debounce.
//   • wrong Content-Type → 415, unauthenticated → 401.

/// Records the outgoing request and serves a canned envelope.
final class ViralRequestsURLProtocol: URLProtocol {
    /// One leg of a multi-call flow — the attach is sign → PUT → record, and
    /// asserting on the LAST request alone would miss the order and the PUT.
    struct Leg: Sendable {
        let url: URL
        let method: String
        let body: Data?
        let headers: [String: String]
    }

    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var status = 201
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)
    nonisolated(unsafe) static var legs: [Leg] = []
    /// Per-request answer, keyed on the URL. Nil falls back to status/responseBody.
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.viralBodyStreamData()
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedBody = body
        Self.requestCount += 1
        Self.legs.append(
            Leg(
                url: request.url!,
                method: request.httpMethod ?? "",
                body: body,
                headers: request.allHTTPHeaderFields ?? [:]))

        let (status, payload) =
            Self.responder?(request) ?? (Self.status, Self.responseBody)

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func viralBodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// The verbatim 201 body from the drive, with the ids left as the server wrote them.
private let liveCreatedEnvelope = """
{"ok":true,"request":{"id":"cmrqxcr8g000fpobybs75kzel","name":"Cherry Cola Balayage","description":null,"sourceUrl":"https://www.tiktok.com/@x/video/123","links":[],"mediaUrls":[],"requestedCategoryId":null,"requestedCategory":null,"status":"REQUESTED","moderationStatus":"APPROVED","reportCount":0,"removedAt":null,"reviewedAt":null,"reviewedByUserId":null,"approvedAt":null,"rejectedAt":null,"adminNotes":null,"createdAt":"2026-07-18T22:14:36.257Z","updatedAt":"2026-07-18T22:14:36.257Z"}}
"""

/// The verbatim 200 from `PATCH /api/v1/viral-service-requests/{id}` (local
/// server, minted CLIENT jwt, 2026-08-15) after attaching one upload to a look
/// that already carried one.
///
/// 🔴 Read `coverImage` in it: **null**, with two `mediaUrls`. The submitter's
/// file is evidence for the review queue; only an admin sets the picture a look
/// is published under.
private let liveAttachedEnvelope = """
{"ok":true,"request":{"id":"demoseed-viral-cherry-cola-balayage","name":"Cherry Cola Balayage","description":null,"sourceUrl":"https://www.instagram.com/p/DemoSeedCherryCola/","links":[],"mediaUrls":["http://localhost:3000/seed-demo/cherry-cola-balayage.jpg","https://rqhhvuaoksuvbvlypztn.supabase.co/storage/v1/object/public/media-public/viral-requests/demoseed-viral-cherry-cola-balayage/uploads/attachment-9f3c2a71.jpg"],"coverImage":null,"requestedCategoryId":null,"requestedCategory":null,"status":"IN_REVIEW","moderationStatus":"APPROVED","reportCount":0,"removedAt":null,"reviewedAt":null,"reviewedByUserId":null,"approvedAt":null,"rejectedAt":null,"adminNotes":null,"createdAt":"2026-08-12T23:35:13.781Z","updatedAt":"2026-08-15T00:08:34.105Z"}}
"""

@Suite(.serialized) struct ViralRequestsServiceTests {
    private func makeService() async -> ViralRequestsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ViralRequestsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.viralrequests.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ViralRequestsService(api: api)
    }

    private func reset() {
        ViralRequestsURLProtocol.capturedPath = nil
        ViralRequestsURLProtocol.capturedMethod = nil
        ViralRequestsURLProtocol.capturedBody = nil
        ViralRequestsURLProtocol.requestCount = 0
        ViralRequestsURLProtocol.status = 201
        ViralRequestsURLProtocol.responseBody = Data(liveCreatedEnvelope.utf8)
        ViralRequestsURLProtocol.legs = []
        ViralRequestsURLProtocol.responder = nil
    }

    private func decodedBody() throws -> [String: Any] {
        let data = try #require(ViralRequestsURLProtocol.capturedBody)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    // MARK: - The verbatim capture

    @Test func decodesTheLiveCreatedEnvelope() async throws {
        reset()

        let created = try await makeService().submit(
            name: "Cherry Cola Balayage",
            sourceUrl: "https://www.tiktok.com/@x/video/123"
        )

        #expect(ViralRequestsURLProtocol.capturedPath == "/api/v1/viral-service-requests")
        #expect(ViralRequestsURLProtocol.capturedMethod == "POST")
        #expect(created.id == "cmrqxcr8g000fpobybs75kzel")
        #expect(created.name == "Cherry Cola Balayage")
        #expect(created.status == "REQUESTED")
    }

    @Test func sendsNameAndSourceUrl() async throws {
        reset()

        _ = try await makeService().submit(
            name: "Cherry Cola Balayage",
            sourceUrl: "https://www.tiktok.com/@x/video/123"
        )

        let body = try decodedBody()
        #expect(body["name"] as? String == "Cherry Cola Balayage")
        #expect(body["sourceUrl"] as? String == "https://www.tiktok.com/@x/video/123")
    }

    /// The web form sends `sourceUrl: trimmed || undefined`, i.e. the key is
    /// ABSENT when blank — not null, not "". Sending `null` would be a different
    /// request, so pin the omission rather than trusting the encoder.
    @Test func omitsSourceUrlEntirelyWhenAbsent() async throws {
        reset()

        _ = try await makeService().submit(name: "No Link Look")

        let body = try decodedBody()
        #expect(body["name"] as? String == "No Link Look")
        #expect(body["sourceUrl"] == nil)
        #expect(body.keys.count == 1)
    }

    /// A future server field must not throw and lose a request that was recorded.
    @Test func ignoresUnknownResponseFields() async throws {
        reset()
        ViralRequestsURLProtocol.responseBody = Data("""
        {"ok":true,"request":{"id":"v_1","name":"Future","status":"REQUESTED","boostScore":42}}
        """.utf8)

        let created = try await makeService().submit(name: "Future")

        #expect(created.id == "v_1")
        #expect(created.status == "REQUESTED")
    }

    /// `status` is decoded as a String on purpose: an unknown future value must
    /// still decode, or the person would be told their submission failed when the
    /// server actually stored it.
    @Test func acceptsAnUnknownFutureStatus() async throws {
        reset()
        ViralRequestsURLProtocol.responseBody = Data("""
        {"ok":true,"request":{"id":"v_2","name":"Later","status":"AWAITING_TRIAGE"}}
        """.utf8)

        let created = try await makeService().submit(name: "Later")

        #expect(created.status == "AWAITING_TRIAGE")
    }

    @Test func toleratesAMissingStatus() async throws {
        reset()
        ViralRequestsURLProtocol.responseBody = Data("""
        {"ok":true,"request":{"id":"v_3","name":"No status"}}
        """.utf8)

        let created = try await makeService().submit(name: "No status")

        #expect(created.status == nil)
    }

    // MARK: - The server's validation, surfaced verbatim

    /// Driven: the handler READS the body — a bad URL really is a 400 with copy
    /// that is already user-facing, so the UI shows it rather than a generic line.
    @Test func surfacesTheServerValidationMessage() async throws {
        reset()
        ViralRequestsURLProtocol.status = 400
        ViralRequestsURLProtocol.responseBody = Data("""
        {"ok":false,"error":"sourceUrl must be a valid URL.","code":"INVALID_VIRAL_REQUEST_INPUT"}
        """.utf8)

        do {
            _ = try await makeService().submit(name: "Bad URL Look", sourceUrl: "not a url")
            Issue.record("expected the 400 to throw")
        } catch let error as APIError {
            #expect(error.userMessage == "sourceUrl must be a valid URL.")
        }
    }

    @Test func surfacesTheNameLengthMessage() async throws {
        reset()
        ViralRequestsURLProtocol.status = 400
        ViralRequestsURLProtocol.responseBody = Data("""
        {"ok":false,"error":"Viral request name must be 160 characters or fewer.","code":"INVALID_VIRAL_REQUEST_INPUT"}
        """.utf8)

        do {
            _ = try await makeService().submit(name: String(repeating: "a", count: 161))
            Issue.record("expected the 400 to throw")
        } catch let error as APIError {
            #expect(error.userMessage == "Viral request name must be 160 characters or fewer.")
        }
    }

    // MARK: - The draft (validation kept out of the view)

    @Test func draftRefusesABlankName() {
        #expect(ViralLookDraft(name: "", sourceUrl: "").canSubmit == false)
        #expect(ViralLookDraft(name: "   ", sourceUrl: "https://x.com").canSubmit == false)
        #expect(ViralLookDraft(name: "Bob", sourceUrl: "").canSubmit == true)
    }

    @Test func draftTrimsBothFieldsAndNilsTheBlankUrl() {
        let draft = ViralLookDraft(name: "  Glazed Donut Bob  ", sourceUrl: "   ")
        #expect(draft.trimmedName == "Glazed Donut Bob")
        #expect(draft.trimmedSourceUrl == nil)
    }

    @Test func draftClampsTheNameToTheServerLimit() {
        let long = String(repeating: "a", count: 200)
        #expect(ViralLookDraft.clampedName(long).count == ViralLookDraft.nameLimit)
        #expect(ViralLookDraft.clampedName("short") == "short")
    }

    /// A blank draft must not reach the network at all — with no idempotency key
    /// server-side, every request that gets through is a row somebody moderates.
    @Test func submittingABlankDraftSendsNoRequest() async throws {
        reset()

        let result = try await makeService().submit(draft: ViralLookDraft(name: "  ", sourceUrl: ""))

        #expect(result == nil)
        #expect(ViralRequestsURLProtocol.requestCount == 0)
        #expect(ViralRequestsURLProtocol.capturedPath == nil)
    }

    @Test func submittingADraftSendsItsTrimmedFields() async throws {
        reset()

        let created = try await makeService().submit(
            draft: ViralLookDraft(name: "  Cherry Cola Balayage ", sourceUrl: " https://www.tiktok.com/@x/video/123 ")
        )

        #expect(created?.name == "Cherry Cola Balayage")
        let body = try decodedBody()
        #expect(body["name"] as? String == "Cherry Cola Balayage")
        #expect(body["sourceUrl"] as? String == "https://www.tiktok.com/@x/video/123")
        #expect(ViralRequestsURLProtocol.requestCount == 1)
    }

    // MARK: - Attaching the submitter's photo or video

    private func makeUploadingService() async -> ViralRequestsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ViralRequestsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.viralrequests.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        // The upload leg needs the same public Supabase creds every other native
        // uploader signs with; without them `attach` refuses before the network.
        // The storage PUT gets the same mocked session — otherwise it is the one
        // leg that would leave the machine.
        return ViralRequestsService(
            api: api,
            uploadSession: session,
            supabaseURL: URL(string: "https://project.supabase.co")!,
            supabaseKey: "publishable-key"
        )
    }

    /// Routes the three legs. The upload-init envelope is built from the route's
    /// own `jsonOk(...)` rather than captured: `getStorageEnvironmentMismatch`
    /// refuses to sign from a local database against a remote bucket, so that leg
    /// cannot be driven on a dev machine at all. The PATCH envelope below IS a
    /// verbatim capture.
    private func installAttachResponder(uploadStatus: Int = 200, patchStatus: Int = 200) {
        ViralRequestsURLProtocol.responder = { request in
            let path = request.url?.path ?? ""

            if path.hasSuffix("/viral-service-requests/upload") {
                return (
                    uploadStatus,
                    Data("""
                    {"ok":true,"requestId":"demoseed-viral-cherry-cola-balayage","bucket":"media-public","path":"viral-requests/demoseed-viral-cherry-cola-balayage/uploads/attachment-9f3c2a71.jpg","token":"signed-token","signedUrl":"https://project.supabase.co/storage/v1/object/upload/sign/media-public/viral-requests/demoseed-viral-cherry-cola-balayage/uploads/attachment-9f3c2a71.jpg?token=signed-token","publicUrl":"https://rqhhvuaoksuvbvlypztn.supabase.co/storage/v1/object/public/media-public/viral-requests/demoseed-viral-cherry-cola-balayage/uploads/attachment-9f3c2a71.jpg","isPublic":true}
                    """.utf8)
                )
            }

            if path.contains("/storage/v1/object/upload/sign/") {
                return (uploadStatus, Data())
            }

            return (patchStatus, Data(liveAttachedEnvelope.utf8))
        }
    }

    private func attachment(
        contentType: String = "image/jpeg",
        fileExtension: String = "jpg",
        byteCount: Int = 1024
    ) -> ViralLookAttachment {
        ViralLookAttachment(
            data: Data(repeating: 0x41, count: byteCount),
            contentType: contentType,
            fileExtension: fileExtension)
    }

    @Test func attachSignsThenPutsThenRecordsTheUrl() async throws {
        reset()
        installAttachResponder()

        let updated = try await makeUploadingService().attach(
            requestId: "demoseed-viral-cherry-cola-balayage",
            attachment: attachment())

        let legs = ViralRequestsURLProtocol.legs
        #expect(legs.count == 3)

        // 1. sign, keyed on the request the file belongs to
        #expect(legs[0].url.path == "/api/v1/viral-service-requests/upload")
        #expect(legs[0].method == "POST")
        let signData = try #require(legs[0].body)
        let signBody = try #require(
            try JSONSerialization.jsonObject(with: signData) as? [String: Any])
        #expect(signBody["requestId"] as? String == "demoseed-viral-cherry-cola-balayage")
        #expect(signBody["contentType"] as? String == "image/jpeg")
        #expect(signBody["size"] as? Int == 1024)

        // 2. the RLS-critical PUT — never a POST, and upsert must match what the
        //    route signed with (`upsert: false`).
        #expect(legs[1].method == "PUT")
        #expect(legs[1].url.path.hasPrefix("/storage/v1/object/upload/sign/"))
        #expect(legs[1].headers["x-upsert"] == "false")
        #expect(legs[1].headers["apikey"] == "publishable-key")

        // 3. record it — bytes nothing points at are invisible to the reviewer.
        #expect(legs[2].url.path == "/api/v1/viral-service-requests/demoseed-viral-cherry-cola-balayage")
        #expect(legs[2].method == "PATCH")
        let patchData = try #require(legs[2].body)
        let patchBody = try #require(
            try JSONSerialization.jsonObject(with: patchData) as? [String: Any])
        #expect(
            patchBody["mediaUrl"] as? String
                == "https://rqhhvuaoksuvbvlypztn.supabase.co/storage/v1/object/public/media-public/viral-requests/demoseed-viral-cherry-cola-balayage/uploads/attachment-9f3c2a71.jpg")

        #expect(updated.id == "demoseed-viral-cherry-cola-balayage")
    }

    /// 🔴 Attaching must not publish anything: the verbatim 200 carries the
    /// submitter's media AND a null cover. If a future server ever answered with
    /// a cover here, this is the test that says so.
    @Test func attachingLeavesTheLookWithoutACover() async throws {
        reset()
        installAttachResponder()

        _ = try await makeUploadingService().attach(
            requestId: "demoseed-viral-cherry-cola-balayage",
            attachment: attachment())

        let body = try #require(
            try JSONSerialization.jsonObject(
                with: Data(liveAttachedEnvelope.utf8)) as? [String: Any])
        let request = try #require(body["request"] as? [String: Any])
        #expect(request["coverImage"] is NSNull)
        #expect((request["mediaUrls"] as? [String])?.count == 2)
    }

    /// A failed PUT must not be followed by a PATCH — recording a URL whose bytes
    /// never landed puts a broken thumbnail in the review queue.
    @Test func aFailedUploadNeverRecordsTheUrl() async throws {
        reset()
        installAttachResponder(uploadStatus: 500)

        await #expect(throws: (any Error).self) {
            _ = try await makeUploadingService().attach(
                requestId: "demoseed-viral-cherry-cola-balayage",
                attachment: attachment())
        }

        #expect(ViralRequestsURLProtocol.legs.allSatisfy { $0.method != "PATCH" })
    }

    /// Without Supabase creds the PUT could never authorize, so refuse before the
    /// signing call rather than mint a target nothing can write to.
    @Test func attachRefusesWithoutStorageCredentials() async throws {
        reset()
        installAttachResponder()

        await #expect(throws: (any Error).self) {
            _ = try await makeService().attach(
                requestId: "demoseed-viral-cherry-cola-balayage",
                attachment: attachment())
        }

        #expect(ViralRequestsURLProtocol.requestCount == 0)
    }

    @Test func uploadFileNameIsUniquePerAttemptAndKeepsTheExtension() {
        let first = ViralRequestsService.uploadFileName(
            fileExtension: "MOV", nonce: "9F3C2A71-0000-0000-0000-000000000000")
        #expect(first == "attachment-9f3c2a71.mov")

        // A retry mints a different object: the signed token is upsert:false, so
        // reusing the name would make every retry fail on a half-written object.
        #expect(
            ViralRequestsService.uploadFileName(fileExtension: "jpg")
                != ViralRequestsService.uploadFileName(fileExtension: "jpg"))
    }

    @Test func theAttachmentCapMatchesTheSigningRoute() {
        #expect(ViralLookAttachment.maxBytes == 30 * 1024 * 1024)

        let overCap = ViralLookAttachment(
            data: Data(repeating: 0x41, count: ViralLookAttachment.maxBytes + 1),
            contentType: "video/quicktime",
            fileExtension: "mov")
        #expect(overCap.isOverCap)
        #expect(overCap.isVideo)
        #expect(!attachment().isOverCap)
        #expect(!attachment().isVideo)
    }
}
