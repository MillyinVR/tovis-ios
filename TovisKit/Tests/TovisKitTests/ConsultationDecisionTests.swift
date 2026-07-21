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
    nonisolated(unsafe) static var responseStatus = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedBody = request.httpBody ?? request.consultationBodyStreamData()
        Self.capturedIdempotencyKey = request.value(forHTTPHeaderField: "idempotency-key")

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
        ConsultationURLProtocol.responseStatus = 200
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

    // Approving is a real scheduling write server-side: since tovis-app #699 it
    // refuses with 409 TIME_BLOCKED when the pro's proposed extra services would
    // run the appointment into their own blocked time. Both call sites
    // (HomeView.decide, BookingDetailView.decide) show `APIError.userMessage`
    // inline, so the client only sees something useful if the envelope's `error`
    // actually survives decoding as the message.
    //
    // This was worth pinning: tovis-app's in-app decision route had no
    // isBookingError branch and turned every booking error into a bare 500, so
    // this path used to render "Internal server error" to the client. Nothing on
    // this side would have caught that — every existing case here serves 200.
    @Test func blockedTimeRefusalSurfacesTheServerMessageAndCode() async throws {
        reset()
        ConsultationURLProtocol.responseStatus = 409
        ConsultationURLProtocol.responseBody = Data("""
        {"ok":false,\
        "error":"These services run into time your pro has blocked off. Ask them to update the proposal.",\
        "code":"TIME_BLOCKED","retryable":true,"uiAction":"PICK_NEW_SLOT"}
        """.utf8)

        let service = await makeService()

        await #expect(throws: APIError.self) {
            try await service.decideConsultation(bookingId: "bk_1", .approve)
        }

        do {
            try await service.decideConsultation(bookingId: "bk_1", .approve)
            Issue.record("expected the 409 to throw")
        } catch let error as APIError {
            guard case let .server(status, message, code) = error else {
                Issue.record("expected APIError.server, got \(error)")
                return
            }
            #expect(status == 409)
            #expect(code == "TIME_BLOCKED")
            // The client must see the pro-facing explanation, not a generic
            // "Something went wrong." fallback.
            #expect(message == "These services run into time your pro has blocked off. Ask them to update the proposal.")
            #expect(error.userMessage == message)
        }
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
