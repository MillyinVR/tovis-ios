import Foundation
import Testing
@testable import TovisKit

// Camera C6 — the smart 9:16 focal-point crop. Proves two things:
//   1. `MediaFocalPoint` validation matches the web `resolveFocalPoint`
//      (`lib/media/focalPoint.ts`): only a finite pair within [0,1] survives;
//      anything else degrades to nil (center) rather than shipping garbage.
//   2. `ProMediaService.confirm(...)` puts `focalX`/`focalY` on the wire when a
//      focal is present, and OMITS both keys when it's nil — the same nil-is-
//      omitted contract `thumbUploadSessionId` relies on, so a faceless shot (or
//      a server that predates the field) stays center.

/// Records the confirm request body and serves a canned `{ item: … }` envelope.
final class FocalConfirmURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedBody = request.httpBody ?? request.focalBodyStreamData()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.itemEnvelope)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static let itemEnvelope = Data("""
    {
      "item": {
        "id": "media_1",
        "mediaType": "IMAGE",
        "visibility": "PRIVATE",
        "phase": "AFTER",
        "caption": null,
        "createdAt": "2026-07-14T00:00:00.000Z",
        "reviewId": null,
        "isEligibleForLooks": false,
        "isFeaturedInPortfolio": false,
        "url": null,
        "thumbUrl": null,
        "renderUrl": null,
        "renderThumbUrl": null
      }
    }
    """.utf8)
}

private extension URLRequest {
    func focalBodyStreamData() -> Data? {
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

@Suite(.serialized) struct MediaFocalPointTests {
    // MARK: - Validation (mirrors web resolveFocalPoint)

    @Test func acceptsAnInRangePair() {
        let focal = MediaFocalPoint(x: 0.3, y: 0.72)
        #expect(focal?.x == 0.3)
        #expect(focal?.y == 0.72)
    }

    @Test func acceptsTheClosedBoundaries() {
        #expect(MediaFocalPoint(x: 0, y: 0) != nil)
        #expect(MediaFocalPoint(x: 1, y: 1) != nil)
    }

    @Test func rejectsOutOfRangeCoordinates() {
        #expect(MediaFocalPoint(x: 1.01, y: 0.5) == nil)
        #expect(MediaFocalPoint(x: 0.5, y: -0.01) == nil)
        #expect(MediaFocalPoint(x: -3, y: 9) == nil)
    }

    @Test func rejectsMissingCoordinates() {
        #expect(MediaFocalPoint(x: nil, y: 0.5) == nil)
        #expect(MediaFocalPoint(x: 0.5, y: nil) == nil)
        #expect(MediaFocalPoint(x: nil, y: nil) == nil)
    }

    @Test func rejectsNonFiniteCoordinates() {
        #expect(MediaFocalPoint(x: .nan, y: 0.5) == nil)
        #expect(MediaFocalPoint(x: 0.5, y: .infinity) == nil)
    }

    // MARK: - Wire contract (confirm body)

    private func makeService() async -> ProMediaService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FocalConfirmURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.focal.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProMediaService(api: api, supabaseURL: nil, supabaseKey: nil)
    }

    private func bodyJSON() throws -> [String: Any] {
        let data = try #require(FocalConfirmURLProtocol.capturedBody)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(json)
    }

    @Test func confirmSendsFocalWhenPresent() async throws {
        FocalConfirmURLProtocol.capturedBody = nil
        let focal = try #require(MediaFocalPoint(x: 0.42, y: 0.18))

        _ = try await makeService().confirm(
            bookingId: "bk_1",
            uploadSessionId: "us_1",
            phase: .after,
            mediaType: .image,
            focal: focal
        )

        #expect(FocalConfirmURLProtocol.capturedPath == "/api/v1/pro/bookings/bk_1/media")
        let body = try bodyJSON()
        #expect(body["focalX"] as? Double == 0.42)
        #expect(body["focalY"] as? Double == 0.18)
    }

    @Test func confirmOmitsFocalKeysWhenNil() async throws {
        FocalConfirmURLProtocol.capturedBody = nil

        _ = try await makeService().confirm(
            bookingId: "bk_1",
            uploadSessionId: "us_1",
            phase: .after,
            mediaType: .image
        )

        let body = try bodyJSON()
        #expect(body["focalX"] == nil)
        #expect(body["focalY"] == nil)
        // The confirm still went out — it's the focal keys that are absent, not the body.
        #expect(body["uploadSessionId"] as? String == "us_1")
    }
}
