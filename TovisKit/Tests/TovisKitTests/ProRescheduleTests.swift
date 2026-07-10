import Foundation
import Testing
@testable import TovisKit

// Proves the pro "reschedule a booking" write path:
//   • ProBookingService.reschedule PATCHes /pro/bookings/{id} as an authenticated
//     native request, carrying { scheduledFor, notifyClient, allow* } with an
//     idempotency-key header — the same PATCH route the web calendar reschedule
//     uses (NOT the client hold-based POST /bookings/{id}/reschedule).
//   • The idempotency key tracks the body: a stable retry reuses it; adding an
//     override flag (the override "book anyway?" retry) mints a fresh key so the
//     server sees a new logical request instead of 409ing on same-key/new-body.
//   • overrideReason is dropped from the JSON when nil (encodeIfPresent).

/// Records the outgoing request and serves a canned envelope.
final class ProRescheduleURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedAuthHeader: String?
    nonisolated(unsafe) static var capturedNativeHeader: String?
    nonisolated(unsafe) static var capturedIdempotencyKey: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedAuthHeader = request.value(forHTTPHeaderField: "Authorization")
        Self.capturedNativeHeader = request.value(forHTTPHeaderField: "x-tovis-native")
        Self.capturedIdempotencyKey = request.value(forHTTPHeaderField: "idempotency-key")
        // URLProtocol strips httpBody into httpBodyStream; read whichever is set.
        Self.capturedBody = request.httpBody ?? request.bodyStreamData()

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

@Suite(.serialized) struct ProRescheduleTests {
    private func makeService() async -> ProBookingService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProRescheduleURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.reschedule.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProBookingService(api: api)
    }

    private func reset(_ body: String = "{\"ok\":true,\"booking\":{\"id\":\"bkg_1\",\"scheduledFor\":\"2026-08-01T15:00:00.000Z\",\"status\":\"ACCEPTED\"},\"meta\":{\"mutated\":true,\"noOp\":false}}") {
        ProRescheduleURLProtocol.capturedPath = nil
        ProRescheduleURLProtocol.capturedMethod = nil
        ProRescheduleURLProtocol.capturedAuthHeader = nil
        ProRescheduleURLProtocol.capturedNativeHeader = nil
        ProRescheduleURLProtocol.capturedIdempotencyKey = nil
        ProRescheduleURLProtocol.capturedBody = nil
        ProRescheduleURLProtocol.status = 200
        ProRescheduleURLProtocol.responseBody = Data(body.utf8)
    }

    @Test func patchesRescheduleAsAuthenticatedNativeRequestWithIdempotencyKey() async throws {
        reset()

        try await makeService().reschedule(
            bookingId: "bkg_1",
            scheduledFor: "2026-08-01T15:00:00.000Z",
            notifyClient: true
        )

        #expect(ProRescheduleURLProtocol.capturedPath == "/api/v1/pro/bookings/bkg_1")
        #expect(ProRescheduleURLProtocol.capturedMethod == "PATCH")
        #expect(ProRescheduleURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(ProRescheduleURLProtocol.capturedNativeHeader == "ios")
        #expect((ProRescheduleURLProtocol.capturedIdempotencyKey ?? "").isEmpty == false)

        let body = try #require(ProRescheduleURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["scheduledFor"] as? String == "2026-08-01T15:00:00.000Z")
        #expect(json["notifyClient"] as? Bool == true)
        // No overrides by default; the flags ride along as explicit false (like createBooking).
        #expect(json["allowOutsideWorkingHours"] as? Bool == false)
        #expect(json["allowShortNotice"] as? Bool == false)
        #expect(json["allowFarFuture"] as? Bool == false)
        // A nil reason is omitted, not sent as null — no serviceItems/status leak either.
        #expect(json["overrideReason"] == nil)
        #expect(json["serviceItems"] == nil)
        #expect(json["status"] == nil)
    }

    @Test func sendsOverrideFlagsAndReasonOnRetry() async throws {
        reset()

        try await makeService().reschedule(
            bookingId: "bkg_1",
            scheduledFor: "2026-08-01T22:00:00.000Z",
            notifyClient: false,
            allowOutsideWorkingHours: true,
            overrideReason: "Client can only make it after close"
        )

        let body = try #require(ProRescheduleURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["notifyClient"] as? Bool == false)
        #expect(json["allowOutsideWorkingHours"] as? Bool == true)
        #expect(json["overrideReason"] as? String == "Client can only make it after close")
    }

    @Test func rescheduleKeyTracksBody() async throws {
        // Same body ⇒ same key (a stable network retry replays server-side)…
        reset()
        try await makeService().reschedule(bookingId: "bkg_1", scheduledFor: "2026-08-01T15:00:00.000Z")
        let firstKey = try #require(ProRescheduleURLProtocol.capturedIdempotencyKey)

        reset()
        try await makeService().reschedule(bookingId: "bkg_1", scheduledFor: "2026-08-01T15:00:00.000Z")
        #expect(ProRescheduleURLProtocol.capturedIdempotencyKey == firstKey)

        // …a new time ⇒ a fresh key.
        reset()
        try await makeService().reschedule(bookingId: "bkg_1", scheduledFor: "2026-08-01T16:00:00.000Z")
        #expect(ProRescheduleURLProtocol.capturedIdempotencyKey != firstKey)

        // …and adding an override flag (the "save it anyway?" retry) ⇒ another fresh key.
        reset()
        try await makeService().reschedule(
            bookingId: "bkg_1",
            scheduledFor: "2026-08-01T15:00:00.000Z",
            allowOutsideWorkingHours: true
        )
        #expect(ProRescheduleURLProtocol.capturedIdempotencyKey != firstKey)
    }
}
