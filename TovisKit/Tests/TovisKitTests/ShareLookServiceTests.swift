import Foundation
import Testing
@testable import TovisKit

// Covers the client "share your look" service (§5 A2): presign a fresh look photo
// (POST /client/uploads kind LOOK_PUBLIC) and publish the look (POST
// /client/bookings/{id}/share-look) — the native mirror of the web ShareLookSheet.
// The signed storage PUT itself is exercised elsewhere (SupabaseSignedUpload), so
// the upload test asserts the presign request shape and lets the unmocked PUT fail.

/// A capturing URLProtocol with its OWN static storage so it never races the other
/// suites' mocks when @Suites run in parallel.
final class ShareLookURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedIdempotencyKey: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)
    nonisolated(unsafe) static var responseStatus = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedIdempotencyKey = request.value(forHTTPHeaderField: "idempotency-key")
        Self.capturedBody = request.httpBody ?? request.bodyStreamData()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.responseStatus, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct ShareLookServiceTests {
    private func makeService() async -> ShareLookService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShareLookURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.sharelook.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ShareLookService(api: api)
    }

    private func reset(_ body: String, status: Int = 200) {
        ShareLookURLProtocol.capturedPath = nil
        ShareLookURLProtocol.capturedMethod = nil
        ShareLookURLProtocol.capturedIdempotencyKey = nil
        ShareLookURLProtocol.capturedBody = nil
        ShareLookURLProtocol.responseBody = Data(body.utf8)
        ShareLookURLProtocol.responseStatus = status
    }

    private static let lookOk = """
    {"ok":true,"look":{"id":"look_1","visibility":"PUBLIC","serviceId":"svc_1","primaryMediaAssetId":"ma_1"}}
    """

    private func capturedJSON() throws -> [String: Any] {
        let data = try #require(ShareLookURLProtocol.capturedBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Publish

    @Test func shareLookPostsToBookingPathWithIdempotencyKeyAndDecodes() async throws {
        reset(Self.lookOk, status: 201)
        let look = try await makeService().shareLook(
            bookingId: "bk_1", name: "  Glazed blonde  ", caption: nil, isPublic: true,
            after: .reuse(mediaAssetId: "ma_after"))

        #expect(ShareLookURLProtocol.capturedPath == "/api/v1/client/bookings/bk_1/share-look")
        #expect(ShareLookURLProtocol.capturedMethod == "POST")
        #expect(ShareLookURLProtocol.capturedIdempotencyKey?.isEmpty == false)

        let json = try capturedJSON()
        #expect(json["name"] as? String == "Glazed blonde") // trimmed
        #expect(json["isPublic"] as? Bool == true)
        let after = try #require(json["after"] as? [String: Any])
        #expect(after["reuseMediaAssetId"] as? String == "ma_after")

        #expect(look.id == "look_1")
        #expect(look.visibility == "PUBLIC")
        #expect(look.serviceId == "svc_1")
        #expect(look.primaryMediaAssetId == "ma_1")
    }

    @Test func shareLookEncodesBeforeUploadSourceAndCaptionWhenPresent() async throws {
        reset(Self.lookOk)
        _ = try await makeService().shareLook(
            bookingId: "bk_1", name: "Look", caption: "  loved it  ", isPublic: false,
            after: .upload(sessionId: "us_after"),
            before: .upload(sessionId: "us_before"))

        let json = try capturedJSON()
        #expect(json["isPublic"] as? Bool == false)
        #expect(json["caption"] as? String == "loved it") // trimmed
        let after = try #require(json["after"] as? [String: Any])
        #expect(after["uploadSessionId"] as? String == "us_after")
        let before = try #require(json["before"] as? [String: Any])
        #expect(before["uploadSessionId"] as? String == "us_before")
    }

    @Test func shareLookOmitsBeforeAndCaptionWhenNil() async throws {
        reset(Self.lookOk)
        _ = try await makeService().shareLook(
            bookingId: "bk_1", name: "Look", caption: "   ", isPublic: true,
            after: .reuse(mediaAssetId: "ma_after"))

        let json = try capturedJSON()
        #expect(json["before"] == nil)            // omitted when nil
        #expect(json["caption"] == nil)           // whitespace-only → omitted
        #expect(json.keys.contains("after"))
    }

    /// A double-tap of the SAME submission mints an identical key (server replays
    /// the first look); an edited submission mints a different key. Guards the
    /// body-derived nonce contract.
    @Test func shareLookIdempotencyKeyIsStableForSameBodyAndShiftsOnEdit() async throws {
        reset(Self.lookOk)
        let service = await makeService()

        _ = try await service.shareLook(
            bookingId: "bk_1", name: "Look", caption: "hi", isPublic: true,
            after: .reuse(mediaAssetId: "ma_after"))
        let first = ShareLookURLProtocol.capturedIdempotencyKey

        _ = try await service.shareLook(
            bookingId: "bk_1", name: "Look", caption: "hi", isPublic: true,
            after: .reuse(mediaAssetId: "ma_after"))
        let same = ShareLookURLProtocol.capturedIdempotencyKey

        _ = try await service.shareLook(
            bookingId: "bk_1", name: "Different name", caption: "hi", isPublic: true,
            after: .reuse(mediaAssetId: "ma_after"))
        let edited = ShareLookURLProtocol.capturedIdempotencyKey

        #expect(first == same)
        #expect(first != edited)
    }

    @Test func shareLookThrowsServerErrorOnFailure() async throws {
        reset("""
        {"ok":false,"error":"Visit not found.","code":"BOOKING_NOT_FOUND"}
        """, status: 404)
        var thrown: APIError?
        do {
            _ = try await makeService().shareLook(
                bookingId: "bk_missing", name: "Look", caption: nil, isPublic: true,
                after: .reuse(mediaAssetId: "ma_after"))
        } catch let error as APIError {
            thrown = error
        }
        let error = try #require(thrown)
        if case .server(let status, _, _) = error {
            #expect(status == 404)
        } else {
            Issue.record("expected APIError.server, got \(error)")
        }
    }

    // MARK: - Presign fresh photo

    @Test func uploadPhotoPresignsWithLookPublicKindPhaseAndBooking() async throws {
        // Valid presign JSON; the subsequent signed PUT hits the unmocked internal
        // upload session and throws — we only assert the presign request shape.
        reset("""
        {"ok":true,"bucket":"media-public","path":"p/x.jpg","token":"tok","signedUrl":null,"publicUrl":null,"isPublic":true,"uploadSessionId":"us_new"}
        """)
        var threw = false
        do {
            _ = try await makeService().uploadPhoto(
                bookingId: "bk_1", phase: .after, imageData: Data([0x1, 0x2, 0x3]))
        } catch {
            threw = true
        }
        #expect(threw)
        #expect(ShareLookURLProtocol.capturedPath == "/api/v1/client/uploads")
        #expect(ShareLookURLProtocol.capturedMethod == "POST")

        let json = try capturedJSON()
        #expect(json["kind"] as? String == "LOOK_PUBLIC")
        #expect(json["phase"] as? String == "AFTER")
        #expect(json["bookingId"] as? String == "bk_1")
        #expect(json["size"] as? Int == 3)
    }

    @Test func uploadPhotoSendsBeforePhaseForBeforeSlot() async throws {
        reset("""
        {"ok":true,"bucket":"media-public","path":"p/x.jpg","token":"tok","signedUrl":null,"publicUrl":null,"isPublic":true,"uploadSessionId":"us_new"}
        """)
        _ = try? await makeService().uploadPhoto(
            bookingId: "bk_9", phase: .before, imageData: Data([0x9]))
        let json = try capturedJSON()
        #expect(json["phase"] as? String == "BEFORE")
        #expect(json["bookingId"] as? String == "bk_9")
    }
}

private extension URLRequest {
    func bodyStreamData() -> Data? {
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
