import Foundation
import Testing
@testable import TovisKit

// K13: the client's in-app answer to K12's "can you make it?" —
// `BookingsService.answerAppointmentConfirmation` → POST
// /client/bookings/{id}/confirmation, body { answer: CONFIRM|DECLINE }.
//
// Web shares one locked core between this route and the SMS token link, so the
// DB outcome is byte-identical either way. What CAN diverge is the request this
// device sends, which is what these pin.

/// Records the outgoing request and serves a canned envelope. Its OWN protocol
/// class + statics: distinct `@Suite` types run in PARALLEL, so sharing another
/// suite's mock would let one test's response body stomp another's
/// ([[swift-suites-run-in-parallel]]).
final class AppointmentConfirmationURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedIdempotencyKey: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedIdempotencyKey = request.value(forHTTPHeaderField: "idempotency-key")
        Self.capturedBody = request.httpBody ?? request.confirmationBodyStreamData()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func confirmationBodyStreamData() -> Data? {
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

@Suite(.serialized) struct AppointmentConfirmationServiceTests {
    private func makeAPI() async -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppointmentConfirmationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.confirmation.tests")
        await tokenStore.save("session.token.value")
        return APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
    }

    private func reset(_ body: Data) {
        AppointmentConfirmationURLProtocol.capturedPath = nil
        AppointmentConfirmationURLProtocol.capturedMethod = nil
        AppointmentConfirmationURLProtocol.capturedIdempotencyKey = nil
        AppointmentConfirmationURLProtocol.capturedBody = nil
        AppointmentConfirmationURLProtocol.status = 200
        AppointmentConfirmationURLProtocol.responseBody = body
    }

    private func bodyJSON() throws -> [String: Any] {
        let data = try #require(AppointmentConfirmationURLProtocol.capturedBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func confirmPostsTheAnswerToTheBookingsOwnRoute() async throws {
        reset(Data("""
        {"ok":true,"state":"CLIENT_CONFIRMED",
         "booking":{"id":"bk_1","status":"ACCEPTED","scheduledFor":"2026-08-02T16:30:00.000Z"},
         "meta":{}}
        """.utf8))
        let service = BookingsService(api: await makeAPI())

        let result = try await service.answerAppointmentConfirmation(
            bookingId: "bk_1", answer: .confirm)

        #expect(AppointmentConfirmationURLProtocol.capturedPath
                == "/api/v1/client/bookings/bk_1/confirmation")
        #expect(AppointmentConfirmationURLProtocol.capturedMethod == "POST")
        #expect(try bodyJSON()["answer"] as? String == "CONFIRM")
        #expect(result.resolvedState == .clientConfirmed)
    }

    @Test func declinePostsDeclineAndTheSlotIsUNTOUCHED() async throws {
        // 🔴 Decision D5: an unconfirmed appointment NEVER auto-cancels. The
        // server's own echo says the booking is still ACCEPTED after a decline,
        // and this pins that the device reads it that way — a client who
        // declines has told their pro, not cancelled on them.
        reset(Data("""
        {"ok":true,"state":"DECLINED",
         "booking":{"id":"bk_2","status":"ACCEPTED","scheduledFor":"2026-08-02T16:30:00.000Z"},
         "meta":{}}
        """.utf8))
        let service = BookingsService(api: await makeAPI())

        let result = try await service.answerAppointmentConfirmation(
            bookingId: "bk_2", answer: .decline)

        #expect(try bodyJSON()["answer"] as? String == "DECLINE")
        #expect(result.resolvedState == .declined)
        #expect(result.booking?.status == "ACCEPTED")
    }

    @Test func sendsNoIdempotencyKeyBecauseReStampingIsTheDesignedBehaviour() async throws {
        // Every OTHER client mutation here mints one (consultation, waitlist
        // offer, aftercare rebook) — this one deliberately does not. Web's route
        // enforces none, and K11's rule is latest-answer-wins, so a client who
        // changes their mind inside one time bucket must not collide with their
        // own earlier answer and get a 409.
        reset(Data(#"{"ok":true,"state":"CLIENT_CONFIRMED","booking":null,"meta":{}}"#.utf8))
        let service = BookingsService(api: await makeAPI())

        _ = try await service.answerAppointmentConfirmation(bookingId: "bk_3", answer: .confirm)

        #expect(AppointmentConfirmationURLProtocol.capturedIdempotencyKey == nil)
    }

    @Test func aRefusalSurfacesAsAnAPIErrorRatherThanASilentSuccess() async throws {
        // The loop flag is off, or the session already started: the route 409s
        // APPOINTMENT_CONFIRMATION_UNAVAILABLE. The card must show that message,
        // never quietly paint the answer as landed.
        reset(Data("""
        {"ok":false,"error":"APPOINTMENT_CONFIRMATION_UNAVAILABLE",
         "userMessage":"This appointment can no longer be confirmed."}
        """.utf8))
        AppointmentConfirmationURLProtocol.status = 409
        let service = BookingsService(api: await makeAPI())

        await #expect(throws: (any Error).self) {
            _ = try await service.answerAppointmentConfirmation(
                bookingId: "bk_4", answer: .confirm)
        }
    }
}
