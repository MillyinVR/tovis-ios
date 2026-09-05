import Foundation
import Testing
@testable import TovisKit

private final class ConsultURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            captured.httpBody = bytes
        }
        Self.requests.append(captured)
        let (status, data) = Self.responder?(captured) ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct ConsultServiceTests {
    private func makeService() async -> ConsultService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsultURLProtocol.self]
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.consult.tests")
        await tokenStore.save("consult.test.token")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ConsultService(
            api: api,
            uploadSession: session,
            supabaseURL: URL(string: "https://storage.test"),
            supabaseKey: "publishable-test-key"
        )
    }

    private func reset() {
        ConsultURLProtocol.requests = []
        ConsultURLProtocol.responder = nil
    }

    private func root() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: fixture("consultFlow")) as? [String: Any])
    }

    private func captureState(_ key: String = "capture") throws -> [String: Any] {
        let root = try root()
        if key == "capture" {
            return try #require((root[key] as? [String: Any])?["capture"] as? [String: Any])
        }
        return try #require(root[key] as? [String: Any])
    }

    private func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }

    @Test func captureUsesOnlyServerMintedPrivateURLAndBoundMutationBodies() async throws {
        reset()
        let accepted = try captureState()
        let rejected = try captureState("captureRejected")
        ConsultURLProtocol.responder = { request in
            switch request.url!.path {
            case "/api/v1/client/consult/consult_fixture_1/capture/uploads":
                return (200, self.json([
                    "upload": [
                        "uploadSessionId": "upload_1", "shotKey": "hair_back",
                        "shotPackVersion": 2, "schemaVersion": 1,
                        "contentType": "image/jpeg", "maxBytes": 10,
                        "expiresAt": "2026-08-11T19:00:00.000Z",
                        "rawExpiresAt": "2026-08-12T18:00:00.000Z",
                        "token": "signed-token",
                        "signedUrl": "https://storage.test/storage/v1/object/upload/sign/media-private/consult-raw/v1/opaque.jpg?token=signed-token"
                    ],
                    "replayed": false
                ]))
            case "/storage/v1/object/upload/sign/media-private/consult-raw/v1/opaque.jpg":
                return (200, Data("{}".utf8))
            case "/api/v1/client/consult/consult_fixture_1/capture/attach":
                return (200, self.json([
                    "capture": rejected, "captureId": "capture_back_1", "replayed": false,
                ]))
            case "/api/v1/client/consult/consult_fixture_1/capture/capture_back_1/quality":
                return (200, self.json([
                    "quality": [
                        "captureId": "capture_back_1", "accepted": true,
                        "reasonCode": "PASS", "retakeTip": NSNull(),
                        "checkedAt": "2026-08-11T18:10:00.000Z"
                    ],
                    "capture": accepted,
                    "replayed": false
                ]))
            default:
                return (404, Data("{\"ok\":false}".utf8))
            }
        }

        let rejectedState = try JSONDecoder().decode(
            ConsultCaptureState.self,
            from: json(rejected)
        )
        let pack = rejectedState.shotPack
        let shot = try #require(pack.shots.first)
        let bytes = Data("0123456789".utf8)
        let keys = ConsultCaptureMutationKeys(issue: "issue-key", attach: "attach-key", quality: "quality-key")
        let service = await makeService()

        // The three legs the durable queue drives, in the order it drives them.
        let ticket = try await service.issueCaptureUpload(
            consultId: "consult_fixture_1", shotKey: shot.key,
            shotPackVersion: pack.version, schemaVersion: pack.schemaVersion,
            sizeBytes: bytes.count, idempotencyKey: keys.issue
        )
        // The PUT goes only to the exact server-minted URL, shaped by the one
        // place that shapes it — the same call the queue's background task makes.
        try await SupabaseSignedUpload.putSignedURL(
            session: URLSession(configuration: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [ConsultURLProtocol.self]
                return configuration
            }()),
            supabaseURL: URL(string: "https://storage.test"),
            supabaseKey: "publishable-test-key",
            signedURL: try #require(ticket.signedUrl.flatMap(URL.init(string:))),
            expectedToken: ticket.token,
            data: bytes,
            contentType: "image/jpeg"
        )
        let attached = try await service.attachCapture(
            consultId: "consult_fixture_1", uploadSessionId: ticket.uploadSessionId,
            shotKey: shot.key, shotPackVersion: pack.version,
            schemaVersion: pack.schemaVersion, idempotencyKey: keys.attach
        )
        let response = try await service.checkCaptureQuality(
            consultId: "consult_fixture_1", captureId: attached.captureId,
            shotPackVersion: pack.version, schemaVersion: pack.schemaVersion,
            idempotencyKey: keys.quality
        )

        #expect(attached.captureId == "capture_back_1")
        #expect(response.quality.accepted)
        #expect(response.capture.hasAllAcceptedShots)
        #expect(ConsultURLProtocol.requests.count == 4)
        let storage = try #require(ConsultURLProtocol.requests.first { $0.url?.host == "storage.test" })
        #expect(storage.httpMethod == "PUT")
        #expect(storage.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(storage.value(forHTTPHeaderField: "apikey") == "publishable-test-key")
        #expect(storage.httpBody == bytes)

        let apiRequests = ConsultURLProtocol.requests.filter { $0.url?.host == "test.local" }
        #expect(apiRequests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer consult.test.token"
        })
        let bodies = apiRequests.compactMap(\.httpBody).compactMap { String(data: $0, encoding: .utf8) }
        #expect(bodies.allSatisfy { !$0.contains("consult-raw") })
        #expect(bodies.allSatisfy { !$0.contains("storagePath") })
        #expect(bodies.allSatisfy { !$0.contains("0123456789") })
        #expect(bodies.contains { $0.contains("issue-key") && $0.contains("hair_back") })
        #expect(bodies.contains { $0.contains("attach-key") && $0.contains("upload_1") })
        #expect(bodies.contains { $0.contains("quality-key") })
    }

    /// The issue leg REPLAYS: the same key returns the same upload session with
    /// a fresh signed URL, and the service must accept that rather than treat a
    /// second call as a contract violation. (Resuming a chain across a process
    /// death is the durable queue's job and is tested there; this is the piece
    /// of it the service owns.)
    @Test func issueReplaysUnderTheSameKeyAndBindsToTheSameUploadSession() async throws {
        reset()
        let rejected = try captureState("captureRejected")
        nonisolated(unsafe) var issueCalls = 0
        ConsultURLProtocol.responder = { request in
            switch request.url!.path {
            case "/api/v1/client/consult/consult_fixture_1/capture/uploads":
                issueCalls += 1
                return (200, self.json([
                    "upload": [
                        "uploadSessionId": "upload_retry", "shotKey": "hair_back",
                        "shotPackVersion": 2, "schemaVersion": 1,
                        "contentType": "image/jpeg", "maxBytes": 3,
                        "expiresAt": "2026-08-11T19:00:00.000Z",
                        "rawExpiresAt": "2026-08-12T18:00:00.000Z",
                        "token": "retry-token-\(issueCalls)",
                        "signedUrl": "https://storage.test/storage/v1/object/upload/sign/media-private/consult-raw/v1/retry.jpg?token=retry-token-\(issueCalls)"
                    ], "replayed": issueCalls > 1
                ]))
            default:
                return (404, Data())
            }
        }

        let state = try JSONDecoder().decode(ConsultCaptureState.self, from: json(rejected))
        let pack = state.shotPack
        let shot = try #require(pack.shots.first)
        let service = await makeService()

        let first = try await service.issueCaptureUpload(
            consultId: "consult_fixture_1", shotKey: shot.key,
            shotPackVersion: pack.version, schemaVersion: pack.schemaVersion,
            sizeBytes: 3, idempotencyKey: "same-issue"
        )
        let second = try await service.issueCaptureUpload(
            consultId: "consult_fixture_1", shotKey: shot.key,
            shotPackVersion: pack.version, schemaVersion: pack.schemaVersion,
            sizeBytes: 3, idempotencyKey: "same-issue"
        )

        #expect(first.uploadSessionId == second.uploadSessionId)
        #expect(first.token != second.token)
        let bodies = ConsultURLProtocol.requests
            .compactMap(\.httpBody)
            .compactMap { String(data: $0, encoding: .utf8) }
        #expect(bodies.count == 2)
        #expect(bodies.allSatisfy { $0.contains("same-issue") })
        #expect(bodies[0] == bodies[1])
    }

    /// A ticket that does not describe the photo in hand is refused rather than
    /// uploaded into. `maxBytes` is part of the server's request hash, so a
    /// mismatch here means the ticket belongs to different bytes.
    @Test func issueRefusesATicketBoundToDifferentBytes() async throws {
        reset()
        let rejected = try captureState("captureRejected")
        ConsultURLProtocol.responder = { _ in
            (200, self.json([
                "upload": [
                    "uploadSessionId": "upload_x", "shotKey": "hair_back",
                    "shotPackVersion": 2, "schemaVersion": 1,
                    "contentType": "image/jpeg", "maxBytes": 999,
                    "expiresAt": "2026-08-11T19:00:00.000Z",
                    "rawExpiresAt": "2026-08-12T18:00:00.000Z",
                    "token": "t",
                    "signedUrl": "https://storage.test/storage/v1/object/upload/sign/media-private/consult-raw/v1/x.jpg?token=t"
                ], "replayed": false
            ]))
        }
        let state = try JSONDecoder().decode(ConsultCaptureState.self, from: json(rejected))
        let shot = try #require(state.shotPack.shots.first)
        let service = await makeService()
        await #expect(throws: ConsultClientFailure.contractMismatch) {
            _ = try await service.issueCaptureUpload(
                consultId: "consult_fixture_1", shotKey: shot.key,
                shotPackVersion: state.shotPack.version,
                schemaVersion: state.shotPack.schemaVersion,
                sizeBytes: 3, idempotencyKey: "k"
            )
        }
    }

    private func inspirationEnvelope(_ key: String) throws -> [String: Any] {
        try #require(try root()[key] as? [String: Any])
    }

    /// The fixture's plain state envelopes, as the mutation-route response
    /// shape (state + `replayed`) the attach/answers endpoints return.
    private func inspirationMutationEnvelope(_ key: String) throws -> [String: Any] {
        var envelope = try inspirationEnvelope(key)
        if envelope["replayed"] == nil { envelope["replayed"] = false }
        return envelope
    }

    @Test func inspirationSkipPostsAnExplicitSourceNoneDecision() async throws {
        reset()
        let skipped = try inspirationEnvelope("inspirationSkipped")
        ConsultURLProtocol.responder = { request in
            guard request.url!.path == "/api/v1/client/consult/consult_fixture_1/inspiration",
                  request.httpMethod == "POST" else { return (404, Data()) }
            return (200, self.json(skipped))
        }

        let state = try await makeService().skipInspiration(
            consultId: "consult_fixture_1", schemaVersion: 1, idempotencyKey: "skip-key"
        )
        #expect(state.isComplete)
        #expect(state.source == nil)

        let body = try #require(ConsultURLProtocol.requests.first?.httpBody)
        let text = try #require(String(data: body, encoding: .utf8))
        #expect(text.contains("\"source\":\"NONE\""))
        #expect(text.contains("skip-key"))
        #expect(text.contains("\"schemaVersion\":1"))
    }

    @Test func inspirationUploadUsesOnlyServerMintedPrivateURLThenAttaches() async throws {
        reset()
        let questioning = try inspirationMutationEnvelope("inspirationQuestion")
        ConsultURLProtocol.responder = { request in
            switch request.url!.path {
            case "/api/v1/client/consult/consult_fixture_1/inspiration/uploads":
                return (200, self.json([
                    "upload": [
                        "inspirationId": "inspiration_fixture_1",
                        "schemaVersion": 1,
                        "contentType": "image/jpeg", "maxBytes": 10,
                        "expiresAt": "2026-08-11T18:20:00.000Z",
                        "useExpiresAt": "2026-08-12T18:00:00.000Z",
                        "token": "inspiration-token",
                        "signedUrl": "https://storage.test/storage/v1/object/upload/sign/media-private/consult-inspiration/v1/opaque.jpg?token=inspiration-token"
                    ],
                    "replayed": false
                ]))
            case "/storage/v1/object/upload/sign/media-private/consult-inspiration/v1/opaque.jpg":
                return (200, Data("{}".utf8))
            case "/api/v1/client/consult/consult_fixture_1/inspiration/attach":
                return (200, self.json(questioning))
            default:
                return (404, Data("{\"ok\":false}".utf8))
            }
        }

        let bytes = Data("0123456789".utf8)
        let keys = ConsultInspirationMutationKeys(issue: "issue-key", attach: "attach-key")
        let state = try await makeService().uploadInspiration(
            consultId: "consult_fixture_1", schemaVersion: 1, jpegData: bytes, keys: keys
        )
        #expect(state.source?.inspirationId == "inspiration_fixture_1")
        #expect(state.progress.currentQuestion?.key == "favorite_colors")

        #expect(ConsultURLProtocol.requests.count == 3)
        let storage = try #require(ConsultURLProtocol.requests.first { $0.url?.host == "storage.test" })
        #expect(storage.httpMethod == "PUT")
        #expect(storage.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(storage.value(forHTTPHeaderField: "apikey") == "publishable-test-key")
        #expect(storage.httpBody == bytes)

        let apiRequests = ConsultURLProtocol.requests.filter { $0.url?.host == "test.local" }
        let bodies = apiRequests.compactMap(\.httpBody).compactMap { String(data: $0, encoding: .utf8) }
        #expect(bodies.allSatisfy { !$0.contains("consult-inspiration") })
        #expect(bodies.allSatisfy { !$0.contains("0123456789") })
        #expect(bodies.contains { $0.contains("issue-key") && $0.contains("\"sizeBytes\":10") })
        #expect(bodies.contains { $0.contains("attach-key") && $0.contains("inspiration_fixture_1") })
    }

    @Test func inspirationAnswerOmitsTextAndSentimentUnlessBothArePresent() async throws {
        reset()
        let texting = try inspirationMutationEnvelope("inspirationTextQuestion")
        let complete = try inspirationMutationEnvelope("inspirationComplete")
        nonisolated(unsafe) var calls = 0
        ConsultURLProtocol.responder = { request in
            guard request.url!.path == "/api/v1/client/consult/consult_fixture_1/inspiration/answers" else {
                return (404, Data())
            }
            calls += 1
            return (200, self.json(calls == 1 ? texting : complete))
        }

        let service = await makeService()
        _ = try await service.answerInspiration(
            consultId: "consult_fixture_1", schemaVersion: 1,
            questionKey: "favorite_colors", selectedValues: ["copper-red"],
            text: nil, sentiment: nil, idempotencyKey: "answer-1"
        )
        let state = try await service.answerInspiration(
            consultId: "consult_fixture_1", schemaVersion: 1,
            questionKey: "other_detail", selectedValues: [],
            text: "love the copper ribbons", sentiment: .good, idempotencyKey: "answer-2"
        )
        #expect(state.isComplete)

        let bodies = ConsultURLProtocol.requests
            .compactMap(\.httpBody)
            .compactMap { String(data: $0, encoding: .utf8) }
        #expect(bodies.count == 2)
        #expect(!bodies[0].contains("\"text\""))
        #expect(!bodies[0].contains("\"sentiment\""))
        #expect(bodies[0].contains("copper-red"))
        #expect(bodies[1].contains("\"text\":\"love the copper ribbons\""))
        #expect(bodies[1].contains("\"sentiment\":\"GOOD\""))
    }

    @Test func inspirationImageReadsOnlyThisConsultsOwnMediaEndpoint() async throws {
        reset()
        ConsultURLProtocol.responder = { request in
            guard request.url!.path == "/api/v1/client/consult/consult_fixture_1/inspiration/media",
                  request.httpMethod == "GET" else { return (404, Data()) }
            return (200, self.json([
                "ok": true,
                "url": "https://storage.test/storage/v1/object/sign/media-private/consult-inspiration/v1/opaque.jpg?token=read-token",
                "expiresInSeconds": 600
            ]))
        }

        let service = await makeService()
        await #expect(throws: ConsultClientFailure.contractMismatch) {
            _ = try await service.inspirationImage(
                consultId: "consult_fixture_1",
                readEndpoint: "/api/v1/looks/look_fixture_1"
            )
        }
        let read = try await service.inspirationImage(
            consultId: "consult_fixture_1",
            readEndpoint: "/api/v1/client/consult/consult_fixture_1/inspiration/media"
        )
        #expect(read.url.contains("token=read-token"))
        #expect(read.expiresInSeconds == 600)
        #expect(ConsultURLProtocol.requests.count == 1)
    }

    /// A route that answers the right SHAPE with an unusable payload is the
    /// same failure as the wrong route. An empty url renders nothing; a
    /// non-positive expiry is not something the panel can renew from.
    @Test func inspirationImageRefusesAnUnusableSignedRead() async throws {
        for payload in [
            ["ok": true, "url": "", "expiresInSeconds": 600],
            ["ok": true, "url": "https://storage.test/read", "expiresInSeconds": 0],
            ["ok": true, "url": "https://storage.test/read", "expiresInSeconds": -1],
        ] as [[String: Any]] {
            reset()
            let body = json(payload)
            ConsultURLProtocol.responder = { _ in (200, body) }
            let service = await makeService()
            await #expect(throws: ConsultClientFailure.contractMismatch) {
                _ = try await service.inspirationImage(
                    consultId: "consult_fixture_1",
                    readEndpoint: "/api/v1/client/consult/consult_fixture_1/inspiration/media"
                )
            }
        }
    }

    @Test func partialPackProceedPostsToTheProceedRouteAndReturnsServerCapture() async throws {
        reset()
        let proceeded = try inspirationEnvelope("captureProceed")
        ConsultURLProtocol.responder = { request in
            guard request.url!.path == "/api/v1/client/consult/consult_fixture_1/capture/proceed",
                  request.httpMethod == "POST" else { return (404, Data()) }
            return (200, self.json(proceeded))
        }

        let capture = try await makeService().proceedWithAccepted(consultId: "consult_fixture_1")
        #expect(capture.status == .analysisPending)
        #expect(!capture.hasAllAcceptedShots)
    }
}
