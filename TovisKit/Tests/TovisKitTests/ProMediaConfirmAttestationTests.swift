import Foundation
import Testing
@testable import TovisKit

// Proves `ProMediaService.confirm(...)` carries the two capture-attestation
// claims (`capturedAt`, `checksumSha256`) onto the wire exactly like every
// other optional field here: nil-is-omitted, present-is-sent. The server
// mirrors these into MediaCaptureAttestation (tovis-app) as claims to compare
// against its own server-computed hash — never trusted alone — but the wire
// contract itself is what this file is pinning.

/// Records the outgoing request and serves a canned envelope.
final class ProMediaConfirmURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var responseBody = Data("""
    {
      "ok": true,
      "item": {
        "id": "media_1",
        "mediaType": "IMAGE",
        "visibility": "PRO_CLIENT",
        "phase": "BEFORE",
        "caption": null,
        "createdAt": "2026-08-17T00:00:00.000Z",
        "reviewId": null,
        "isEligibleForLooks": false,
        "isFeaturedInPortfolio": false,
        "url": null,
        "thumbUrl": null,
        "renderUrl": "https://signed.example/x.jpg",
        "renderThumbUrl": null
      }
    }
    """.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedBody = request.httpBody ?? request.confirmBodyStreamData()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func confirmBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ProMediaConfirmAttestationTests {
    private func makeService() async -> ProMediaService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProMediaConfirmURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.confirmattestation.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProMediaService(api: api, supabaseURL: nil, supabaseKey: nil)
    }

    private func bodyJSON() throws -> [String: Any] {
        let data = try #require(ProMediaConfirmURLProtocol.capturedBody)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(json)
    }

    @Test func confirmSendsCapturedAtAsIso8601AndTheChecksum() async throws {
        ProMediaConfirmURLProtocol.capturedBody = nil
        let capturedAt = Date(timeIntervalSince1970: 1_755_000_000)
        let checksum = "a".padding(toLength: 64, withPad: "a", startingAt: 0)

        _ = try await makeService().confirm(
            bookingId: "booking_1",
            uploadSessionId: "us_1",
            phase: .before,
            mediaType: .image,
            capturedAt: capturedAt,
            checksumSha256: checksum
        )

        let body = try bodyJSON()
        #expect(body["checksumSha256"] as? String == checksum)
        let capturedAtString = try #require(body["capturedAt"] as? String)
        // Round-trips through the same ISO-8601-with-fractional-seconds
        // formatter `Wire` uses everywhere else on the wire.
        let parsed = try #require(Wire.date(capturedAtString))
        #expect(abs(parsed.timeIntervalSince1970 - capturedAt.timeIntervalSince1970) < 0.001)
    }

    @Test func confirmOmitsCapturedAtAndChecksumWhenNil() async throws {
        ProMediaConfirmURLProtocol.capturedBody = nil

        _ = try await makeService().confirm(
            bookingId: "booking_1",
            uploadSessionId: "us_1",
            phase: .before,
            mediaType: .image
        )

        let body = try bodyJSON()
        // Nil-is-omitted — a server that predates the fields (or a library
        // import with no trustworthy capturedAt claim) must see absent keys,
        // never a literal `null` forcing every server to special-case it.
        #expect(body["capturedAt"] == nil)
        #expect(body["checksumSha256"] == nil)
    }
}
