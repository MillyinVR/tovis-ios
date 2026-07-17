import Foundation
import Testing
@testable import TovisKit

// Proves `ProMediaService.createPost` puts the RIGHT BYTES on the wire — through a
// real `APIClient` + `URLProtocol`, not a mock.
//
// That distinction is the point. A mock-level test asserts the shape the code
// already believes, so reader and mock agree with each other and can both be wrong
// about the server (which is exactly how web's OTP countdown never fired in prod,
// and how `requestVoid` silently dropped `captureErrorDetails`). These tests read
// the encoded JSON back off the request.
//
// The signed PUT is not exercised here: it goes straight to Supabase via
// `SupabaseSignedUpload`, so `supabaseURL` is nil and the upload throws before the
// create. What IS covered is the presign body + the create body — the two requests
// that reach OUR API.

/// Records every outgoing request and serves a canned envelope per path.
final class NewMediaPostURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPaths: [String] = []
    nonisolated(unsafe) static var capturedMethods: [String] = []
    nonisolated(unsafe) static var capturedBodies: [String: Data] = [:]
    nonisolated(unsafe) static var capturedIdempotencyKeys: [String: String] = [:]
    nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.capturedPaths.append(path)
        Self.capturedMethods.append(request.httpMethod ?? "")
        if let body = request.httpBody ?? request.newMediaPostBodyStreamData() {
            Self.capturedBodies[path] = body
        }
        if let key = request.value(forHTTPHeaderField: "Idempotency-Key") {
            Self.capturedIdempotencyKeys[path] = key
        }

        let (status, body) = Self.responses[path] ?? (200, Data("{\"ok\":true}".utf8))
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func newMediaPostBodyStreamData() -> Data? {
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

@Suite(.serialized) struct NewMediaPostServiceTests {
    private func makeService(supabaseURL: URL?) async -> ProMediaService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NewMediaPostURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.newmediapost.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        // The signed PUT goes straight to Supabase on the service's OWN session, so
        // it must be stubbed too — otherwise the pipeline leaves the process and
        // the create is never reached (it hung for 60s before this was injected).
        return ProMediaService(
            api: api, supabaseURL: supabaseURL, supabaseKey: "anon.key",
            uploadSession: session
        )
    }

    private func reset() {
        NewMediaPostURLProtocol.capturedPaths = []
        NewMediaPostURLProtocol.capturedMethods = []
        NewMediaPostURLProtocol.capturedBodies = [:]
        NewMediaPostURLProtocol.capturedIdempotencyKeys = [:]
        NewMediaPostURLProtocol.responses = [:]
    }

    private func json(_ path: String) -> [String: Any] {
        guard let data = NewMediaPostURLProtocol.capturedBodies[path],
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    /// The presign + create envelopes the real routes return.
    private func stubHappyPath() {
        NewMediaPostURLProtocol.responses["/api/v1/pro/uploads"] = (
            200,
            Data("""
            {"kind":"LOOKS_PUBLIC","bucket":"media-public","path":"pro/pro_1/LOOKS_PUBLIC/2026-07/1_a.jpg",
             "token":"signed.token","signedUrl":"https://sb.local/upload","publicUrl":"https://sb.local/pub.jpg",
             "isPublic":true,"cacheBuster":1,"uploadSessionId":"us_1"}
            """.utf8)
        )
        NewMediaPostURLProtocol.responses["/api/v1/pro/media"] = (
            201,
            Data("""
            {"ok":true,"media":{"id":"media_1","professionalId":"pro_1","primaryServiceId":"service_1",
             "mediaType":"IMAGE","visibility":"PUBLIC","caption":"Balayage day","isFeaturedInPortfolio":true,
             "isEligibleForLooks":true,"url":"https://sb.local/pub.jpg","thumbUrl":null,
             "createdAt":"2026-07-16T10:00:00.000Z","services":[{"serviceId":"service_1","name":"Balayage"}]},
             "lookPublication":{"target":{"lookPostId":"look_1"},"action":"publish","result":{"status":"PUBLISHED"},
             "asyncEffects":[]}}
            """.utf8)
        )
    }

    private func looksDraft() -> NewMediaPostDraft {
        var draft = NewMediaPostDraft()
        draft.image = .ready(byteCount: 4)
        draft.serviceIds = ["service_1"]
        draft.isEligibleForLooks = true
        draft.caption = "Balayage day"
        draft.priceStartingAt = "85.00"
        return draft
    }

    @Test("createPost presigns with the draft's kind, then creates against /pro/media")
    func createPostDrivesBothRoutes() async throws {
        reset()
        stubHappyPath()
        // A real signed PUT would leave the app; point it at the stub host so the
        // whole three-step pipeline runs through URLProtocol.
        let service = await makeService(supabaseURL: URL(string: "https://sb.local")!)

        let created = try await service.createPost(
            draft: looksDraft(),
            imageData: Data([0x01, 0x02, 0x03, 0x04]),
            focal: MediaFocalPoint(x: 0.25, y: 0.75)
        )

        // 1 — presign carries the kind + the REAL byte count, and no booking/phase.
        let presign = json("/api/v1/pro/uploads")
        #expect(presign["kind"] as? String == "LOOKS_PUBLIC")
        #expect(presign["contentType"] as? String == "image/jpeg")
        #expect(presign["size"] as? Int == 4)
        #expect(presign["bookingId"] == nil)
        #expect(presign["phase"] == nil)
        #expect(presign["serviceId"] == nil)

        // 2 — the create keys on the session the presign minted, never a client path.
        let create = json("/api/v1/pro/media")
        #expect(create["uploadSessionId"] as? String == "us_1")
        #expect(create["bucket"] == nil)
        #expect(create["path"] == nil)
        #expect(create["visibility"] == nil)  // always server-derived

        // 3 — the focal actually reaches the wire (the whole point of web PR #656).
        #expect(create["focalX"] as? Double == 0.25)
        #expect(create["focalY"] as? Double == 0.75)

        #expect(NewMediaPostURLProtocol.capturedMethods.filter { $0 == "POST" }.count >= 2)
        #expect(created.id == "media_1")
        #expect(created.isEligibleForLooks)
        #expect(created.services.first?.name == "Balayage")
    }

    @Test("The create is keyed to the upload session so a retry can't double-post")
    func createIsIdempotent() async throws {
        reset()
        stubHappyPath()
        let service = await makeService(supabaseURL: URL(string: "https://sb.local")!)

        _ = try await service.createPost(
            draft: looksDraft(), imageData: Data([0x01]), focal: nil
        )
        let firstKey = NewMediaPostURLProtocol.capturedIdempotencyKeys["/api/v1/pro/media"]
        #expect(firstKey?.isEmpty == false)

        // The key is a hash, so it can't be read for the session id — prove it's
        // DERIVED from it instead: a different upload session must key differently,
        // or two genuinely separate posts would collapse onto one asset.
        NewMediaPostURLProtocol.capturedIdempotencyKeys = [:]
        NewMediaPostURLProtocol.responses["/api/v1/pro/uploads"] = (
            200,
            Data("""
            {"bucket":"media-public","path":"pro/pro_1/LOOKS_PUBLIC/2026-07/2_b.jpg",
             "token":"signed.token","signedUrl":"https://sb.local/upload","publicUrl":"https://sb.local/pub2.jpg",
             "isPublic":true,"uploadSessionId":"us_2"}
            """.utf8)
        )
        _ = try await service.createPost(
            draft: looksDraft(), imageData: Data([0x01]), focal: nil
        )
        let secondKey = NewMediaPostURLProtocol.capturedIdempotencyKeys["/api/v1/pro/media"]

        #expect(secondKey?.isEmpty == false)
        #expect(firstKey != secondKey)
    }

    @Test("A faceless photo omits the focal keys entirely")
    func noFocalOmitsKeys() async throws {
        reset()
        stubHappyPath()
        let service = await makeService(supabaseURL: URL(string: "https://sb.local")!)

        _ = try await service.createPost(
            draft: looksDraft(), imageData: Data([0x01]), focal: nil
        )

        let create = json("/api/v1/pro/media")
        // Omitted, not null/zero — a server that predates the focal field ignores
        // the keys, and one that has it centers exactly as before.
        #expect(create.index(forKey: "focalX") == nil)
        #expect(create.index(forKey: "focalY") == nil)
    }

    @Test("A private draft presigns into the private bucket")
    func privateDraftUsesPrivateKind() async throws {
        reset()
        stubHappyPath()
        let service = await makeService(supabaseURL: URL(string: "https://sb.local")!)

        var draft = looksDraft()
        draft.isPrivate = true

        _ = try await service.createPost(draft: draft, imageData: Data([0x01]), focal: nil)

        // Bucket and derived visibility must agree or the create 400s — after the
        // bytes are already uploaded.
        #expect(json("/api/v1/pro/uploads")["kind"] as? String == "PORTFOLIO_PRIVATE")
        #expect(json("/api/v1/pro/media")["isEligibleForLooks"] as? Bool == false)
    }

    @Test("An unmodeled lookPublication can't sink the decode")
    func unexpectedLookPublicationStillDecodes() async throws {
        reset()
        stubHappyPath()
        // The real route returns this key; nothing native reads it. A synthesized
        // Decodable on an optional nested object would fail the WHOLE parent on a
        // shape surprise, so it stays unmodeled — prove a garbage value is ignored.
        NewMediaPostURLProtocol.responses["/api/v1/pro/media"] = (
            201,
            Data("""
            {"ok":true,"media":{"id":"media_1","professionalId":"pro_1","primaryServiceId":"service_1",
             "mediaType":"IMAGE","visibility":"PUBLIC","caption":null,"isFeaturedInPortfolio":true,
             "isEligibleForLooks":true,"url":null,"thumbUrl":null,
             "createdAt":"2026-07-16T10:00:00.000Z","services":[]},
             "lookPublication":"a string where an object was documented"}
            """.utf8)
        )
        let service = await makeService(supabaseURL: URL(string: "https://sb.local")!)

        let created = try await service.createPost(
            draft: looksDraft(), imageData: Data([0x01]), focal: nil
        )
        #expect(created.id == "media_1")
    }
}
