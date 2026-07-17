import Foundation
import Testing
@testable import TovisKit

// Pins the wire contract for claiming a last-minute opening: `BookingService.finalize`
// must send `openingId` (POST /api/v1/bookings/finalize) when the booking is a
// claim, so the server consumes the opening (flips it to BOOKED — a double-claim
// guard) and applies the tier incentive the client was shown. It previously sent
// NO openingId, so on iOS every claimed opening stayed live and was charged at full
// price (the advertised discount silently dropped).
//
// The absence case matters too: a normal booking must NOT send `openingId`, so its
// finalize idempotency key (derived from the body bytes) is unchanged.

/// Records the outgoing request and serves a canned finalized-booking envelope.
final class FinalizeURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var capturedIdempotencyKey: String?
    nonisolated(unsafe) static var responseBody = Data("""
    {"ok":true,"booking":{"id":"bk_1","status":"CONFIRMED",
     "scheduledFor":"2026-07-10T17:00:00.000Z","professionalId":"pro_1"}}
    """.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedBody = request.httpBody ?? request.finalizeBodyStreamData()
        Self.capturedIdempotencyKey = request.value(forHTTPHeaderField: "idempotency-key")

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
    func finalizeBodyStreamData() -> Data? {
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

@Suite(.serialized) struct BookingFinalizeOpeningTests {
    private func makeService() async -> BookingService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FinalizeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.finalize.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return BookingService(api: api)
    }

    private func reset() {
        FinalizeURLProtocol.capturedBody = nil
        FinalizeURLProtocol.capturedIdempotencyKey = nil
    }

    private func bodyJSON() throws -> [String: Any] {
        let body = try #require(FinalizeURLProtocol.capturedBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func claimSendsOpeningId() async throws {
        reset()

        _ = try await makeService().finalize(
            holdId: "hold_1", offeringId: "off_1", openingId: "opening_1")

        let json = try bodyJSON()
        #expect(json["openingId"] as? String == "opening_1")
        #expect(json["holdId"] as? String == "hold_1")
        #expect(json["offeringId"] as? String == "off_1")
    }

    @Test func normalBookingOmitsOpeningIdAndKeepsIdempotencyKey() async throws {
        // A finalize with no openingId must not encode the key at all (optional →
        // encodeIfPresent), so its body — and therefore its derived idempotency key —
        // is byte-identical to the pre-openingId behaviour. Capture the key, then
        // reconstruct the expected one from a body with no openingId.
        reset()

        _ = try await makeService().finalize(holdId: "hold_1", offeringId: "off_1")

        let json = try bodyJSON()
        #expect(json["openingId"] == nil)

        let expectedBody = try JSONEncoder.canonical.encode(FinalizeBookingRequest(
            holdId: "hold_1", offeringId: "off_1",
            locationType: "SALON", addOnIds: [], source: "REQUESTED",
            openingId: nil))
        let expectedKey = buildClientIdempotencyKey(
            scope: "booking", entityId: "hold_1", action: "finalize",
            nonce: idempotencyNonce(expectedBody))
        #expect(FinalizeURLProtocol.capturedIdempotencyKey == expectedKey)
    }
}
