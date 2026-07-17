import Foundation
import Testing
@testable import TovisKit

// Pins the wire contract for the client's consultation approve/decline
// (`BookingsService.decideConsultation` → POST /api/v1/client/bookings/{id}/consultation).
//
// The gated route HARD-REQUIRES an `idempotency-key` header — without it the
// server 400s `IDEMPOTENCY_KEY_REQUIRED` before touching the decision — so the
// header must always be present. This regressed once (the call was the lone
// mutation here that sent no key, so every Approve/Decline tap 400'd) and neither
// the server's route test nor `_decision.test.ts` exercises the real no-key path
// (both mock the idempotency layer). This transport test drives the REAL
// `APIClient` through a capturing `URLProtocol`, so a dropped header fails here.

/// Records the outgoing request and serves a canned envelope.
final class ConsultationURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var capturedIdempotencyKey: String?
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedBody = request.httpBody ?? request.consultationBodyStreamData()
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
    /// URLSession moves a POST body onto `httpBodyStream`; drain it for assertions.
    func consultationBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ConsultationDecisionTests {
    private func makeService() async -> BookingsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConsultationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.consultation.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return BookingsService(api: api)
    }

    private func reset() {
        ConsultationURLProtocol.capturedPath = nil
        ConsultationURLProtocol.capturedMethod = nil
        ConsultationURLProtocol.capturedBody = nil
        ConsultationURLProtocol.capturedIdempotencyKey = nil
        ConsultationURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    private func bodyJSON() throws -> [String: Any] {
        let body = try #require(ConsultationURLProtocol.capturedBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func approvePostsWithIdempotencyKeyAndAction() async throws {
        reset()

        try await makeService().decideConsultation(bookingId: "bk_1", .approve)

        #expect(ConsultationURLProtocol.capturedPath == "/api/v1/client/bookings/bk_1/consultation")
        #expect(ConsultationURLProtocol.capturedMethod == "POST")

        // The header is the whole point of this test — a dropped key 400s the tap.
        let key = try #require(ConsultationURLProtocol.capturedIdempotencyKey)
        #expect(key.split(separator: ":").count == 5)
        // Reconstruct it (same ~60s bucket): the decision is folded into the key's
        // action so APPROVE and REJECT never collide (409) while a double-tap dedupes.
        #expect(key == buildClientIdempotencyKey(
            scope: "client-consultation-decision",
            entityId: "bk_1",
            action: "APPROVE"))

        let json = try bodyJSON()
        #expect(json["action"] as? String == "APPROVE")
    }

    @Test func declineSendsDistinctKeyFromApprove() async throws {
        reset()

        try await makeService().decideConsultation(bookingId: "bk_1", .reject)

        let json = try bodyJSON()
        #expect(json["action"] as? String == "REJECT")

        let key = try #require(ConsultationURLProtocol.capturedIdempotencyKey)
        #expect(key == buildClientIdempotencyKey(
            scope: "client-consultation-decision", entityId: "bk_1", action: "REJECT"))

        // Same booking + same bucket, but a different decision → a different key,
        // so approve and reject can't be dropped as duplicates of each other.
        let approveKey = buildClientIdempotencyKey(
            scope: "client-consultation-decision", entityId: "bk_1", action: "APPROVE")
        #expect(key != approveKey)
    }
}
