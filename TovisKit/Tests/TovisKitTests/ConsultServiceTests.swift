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
        let shot = try #require(rejectedState.shotPack.shots.first)
        let bytes = Data("0123456789".utf8)
        let keys = ConsultCaptureMutationKeys(issue: "issue-key", attach: "attach-key", quality: "quality-key")
        let response = try await makeService().uploadAndCheckCapture(
            consultId: "consult_fixture_1",
            shot: shot,
            pack: rejectedState.shotPack,
            jpegData: bytes,
            keys: keys
        )

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

    @Test func retryReusesIssueUploadAndAttachIdentitiesWithoutUploadingTwice() async throws {
        reset()
        let accepted = try captureState()
        let rejected = try captureState("captureRejected")
        nonisolated(unsafe) var attachCalls = 0
        ConsultURLProtocol.responder = { request in
            switch request.url!.path {
            case "/api/v1/client/consult/consult_fixture_1/capture/uploads":
                return (200, self.json([
                    "upload": [
                        "uploadSessionId": "upload_retry", "shotKey": "hair_back",
                        "shotPackVersion": 2, "schemaVersion": 1,
                        "contentType": "image/jpeg", "maxBytes": 3,
                        "expiresAt": "2026-08-11T19:00:00.000Z",
                        "rawExpiresAt": "2026-08-12T18:00:00.000Z",
                        "token": "retry-token",
                        "signedUrl": "https://storage.test/storage/v1/object/upload/sign/media-private/consult-raw/v1/retry.jpg?token=retry-token"
                    ], "replayed": false
                ]))
            case "/storage/v1/object/upload/sign/media-private/consult-raw/v1/retry.jpg":
                return (200, Data("{}".utf8))
            case "/api/v1/client/consult/consult_fixture_1/capture/attach":
                attachCalls += 1
                if attachCalls == 1 {
                    return (503, Data("{\"ok\":false,\"error\":\"private content must not surface\"}".utf8))
                }
                return (200, self.json([
                    "capture": rejected, "captureId": "capture_retry", "replayed": true,
                ]))
            case "/api/v1/client/consult/consult_fixture_1/capture/capture_retry/quality":
                return (200, self.json([
                    "quality": ["captureId":"capture_retry","accepted":true,"reasonCode":"PASS","retakeTip":NSNull(),"checkedAt":"2026-08-11T18:10:00.000Z"],
                    "capture": accepted, "replayed": false
                ]))
            default:
                return (404, Data())
            }
        }

        let state = try JSONDecoder().decode(ConsultCaptureState.self, from: json(rejected))
        let shot = try #require(state.shotPack.shots.first)
        let service = await makeService()
        let keys = ConsultCaptureMutationKeys(issue: "same-issue", attach: "same-attach", quality: "same-quality")

        await #expect(throws: APIError.self) {
            _ = try await service.uploadAndCheckCapture(
                consultId: "consult_fixture_1", shot: shot, pack: state.shotPack,
                jpegData: Data("abc".utf8), keys: keys
            )
        }
        _ = try await service.uploadAndCheckCapture(
            consultId: "consult_fixture_1", shot: shot, pack: state.shotPack,
            jpegData: Data("abc".utf8), keys: keys
        )

        let paths = ConsultURLProtocol.requests.map { $0.url!.path }
        #expect(paths.filter { $0.hasSuffix("/capture/uploads") }.count == 1)
        #expect(paths.filter { $0 == "/storage/v1/object/upload/sign/media-private/consult-raw/v1/retry.jpg" }.count == 1)
        let attaches = ConsultURLProtocol.requests.filter { $0.url!.path.hasSuffix("/capture/attach") }
        #expect(attaches.count == 2)
        #expect(attaches[0].httpBody == attaches[1].httpBody)
    }
}
