import Foundation
import Testing
@testable import TovisKit

// Proves the money-trail WRITE paths the native inspector uses — the refund and
// the no-show-fee waive — hit the shared `/bookings/{id}/...` routes (NOT `/pro`
// ones) as authenticated native POSTs with an idempotency-key header:
//   • refund POSTs /bookings/{id}/refund, carrying { amountCents?, reason? } with
//     both optionals dropped when nil (a bare body ⇒ a full refund). Its key
//     tracks the body: a stable retry reuses it, an edited amount/reason mints a
//     fresh one (server contract "same key ⇒ same body").
//   • waive POSTs /bookings/{id}/no-show-fee/waive with an empty {} body and a
//     STABLE key — there's no body to vary, and waive is a server-side no-op on
//     repeat, so a double-tap dedupes rather than double-acting.

/// Records the outgoing request and serves a canned envelope.
final class ProMoneyTrailWriteURLProtocol: URLProtocol {
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

@Suite(.serialized) struct ProMoneyTrailWriteTests {
    private func makeService() async -> ProBookingService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProMoneyTrailWriteURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.moneytrail.write.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProBookingService(api: api)
    }

    private func reset(_ body: String = "{\"ok\":true}") {
        ProMoneyTrailWriteURLProtocol.capturedPath = nil
        ProMoneyTrailWriteURLProtocol.capturedMethod = nil
        ProMoneyTrailWriteURLProtocol.capturedAuthHeader = nil
        ProMoneyTrailWriteURLProtocol.capturedNativeHeader = nil
        ProMoneyTrailWriteURLProtocol.capturedIdempotencyKey = nil
        ProMoneyTrailWriteURLProtocol.capturedBody = nil
        ProMoneyTrailWriteURLProtocol.status = 200
        ProMoneyTrailWriteURLProtocol.responseBody = Data(body.utf8)
    }

    // MARK: - Refund

    @Test func fullRefundPostsBareBodyAsAuthenticatedNativeRequest() async throws {
        reset()

        try await makeService().refund(bookingId: "bkg_1")

        #expect(ProMoneyTrailWriteURLProtocol.capturedPath == "/api/v1/bookings/bkg_1/refund")
        #expect(ProMoneyTrailWriteURLProtocol.capturedMethod == "POST")
        #expect(ProMoneyTrailWriteURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(ProMoneyTrailWriteURLProtocol.capturedNativeHeader == "ios")
        #expect((ProMoneyTrailWriteURLProtocol.capturedIdempotencyKey ?? "").isEmpty == false)

        let body = try #require(ProMoneyTrailWriteURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // Full refund ⇒ neither optional is present (server reads a missing amount
        // as "refund the remaining balance").
        #expect(json["amountCents"] == nil)
        #expect(json["reason"] == nil)
    }

    @Test func partialRefundCarriesAmountAndReason() async throws {
        reset()

        try await makeService().refund(bookingId: "bkg_1", amountCents: 2500, reason: "service issue")

        let body = try #require(ProMoneyTrailWriteURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["amountCents"] as? Int == 2500)
        #expect(json["reason"] as? String == "service issue")
    }

    @Test func refundKeyTracksBody() async throws {
        // Same amount + reason ⇒ same key (a stable network retry replays server-side)…
        reset()
        try await makeService().refund(bookingId: "bkg_1", amountCents: 2500, reason: "service issue")
        let firstKey = try #require(ProMoneyTrailWriteURLProtocol.capturedIdempotencyKey)

        reset()
        try await makeService().refund(bookingId: "bkg_1", amountCents: 2500, reason: "service issue")
        #expect(ProMoneyTrailWriteURLProtocol.capturedIdempotencyKey == firstKey)

        // …an edited amount ⇒ a fresh key…
        reset()
        try await makeService().refund(bookingId: "bkg_1", amountCents: 3000, reason: "service issue")
        #expect(ProMoneyTrailWriteURLProtocol.capturedIdempotencyKey != firstKey)

        // …and an edited reason ⇒ another fresh key.
        reset()
        try await makeService().refund(bookingId: "bkg_1", amountCents: 2500, reason: "goodwill")
        #expect(ProMoneyTrailWriteURLProtocol.capturedIdempotencyKey != firstKey)
    }

    // MARK: - Waive no-show fee

    @Test func waivePostsEmptyBodyAsAuthenticatedNativeRequest() async throws {
        reset()

        try await makeService().waiveNoShowFee(bookingId: "bkg_1")

        #expect(ProMoneyTrailWriteURLProtocol.capturedPath == "/api/v1/bookings/bkg_1/no-show-fee/waive")
        #expect(ProMoneyTrailWriteURLProtocol.capturedMethod == "POST")
        #expect(ProMoneyTrailWriteURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(ProMoneyTrailWriteURLProtocol.capturedNativeHeader == "ios")
        #expect((ProMoneyTrailWriteURLProtocol.capturedIdempotencyKey ?? "").isEmpty == false)

        let body = try #require(ProMoneyTrailWriteURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        // No body fields — waive derives everything from the entry server-side.
        #expect(json.isEmpty)
    }

    @Test func waiveKeyIsStableAcrossRepeatTaps() async throws {
        // Waive has no body to vary and is a no-op on repeat, so two taps in the same
        // bucket dedupe on an identical key rather than double-acting.
        reset()
        try await makeService().waiveNoShowFee(bookingId: "bkg_1")
        let firstKey = try #require(ProMoneyTrailWriteURLProtocol.capturedIdempotencyKey)

        reset()
        try await makeService().waiveNoShowFee(bookingId: "bkg_1")
        #expect(ProMoneyTrailWriteURLProtocol.capturedIdempotencyKey == firstKey)

        // A different booking ⇒ a different key (namespaced to the target).
        reset()
        try await makeService().waiveNoShowFee(bookingId: "bkg_2")
        #expect(ProMoneyTrailWriteURLProtocol.capturedIdempotencyKey != firstKey)
    }
}
