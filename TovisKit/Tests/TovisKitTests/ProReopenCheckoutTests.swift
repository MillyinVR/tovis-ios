import Foundation
import Testing
@testable import TovisKit

// Proves ProBookingService.reopenCheckout(bookingId:) POSTs the dedicated reopen
// route (M9 follow-up: undo a mistaken manual mark-paid / waive) as an
// authenticated native request with an idempotency-key header and no body, and
// that a server refusal surfaces as APIError. Also pins the client-side gate
// (`ProSessionStateCheckout.isManuallyClosed`) that decides whether the undo
// affordance is shown.

/// Serves a canned reopen response and records the outgoing request.
final class ProReopenCheckoutURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedAuthHeader: String?
    nonisolated(unsafe) static var capturedNativeHeader: String?
    nonisolated(unsafe) static var capturedIdempotencyKey: String?
    nonisolated(unsafe) static var capturedBodyLength: Int?
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
        Self.capturedBodyLength = request.httpBody?.count

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct ProReopenCheckoutTests {
    private func makeService() async -> ProBookingService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProReopenCheckoutURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.reopencheckout.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProBookingService(api: api)
    }

    private func reset(status: Int, body: String) {
        ProReopenCheckoutURLProtocol.capturedPath = nil
        ProReopenCheckoutURLProtocol.capturedMethod = nil
        ProReopenCheckoutURLProtocol.capturedAuthHeader = nil
        ProReopenCheckoutURLProtocol.capturedNativeHeader = nil
        ProReopenCheckoutURLProtocol.capturedIdempotencyKey = nil
        ProReopenCheckoutURLProtocol.capturedBodyLength = nil
        ProReopenCheckoutURLProtocol.status = status
        ProReopenCheckoutURLProtocol.responseBody = Data(body.utf8)
    }

    @Test func postsReopenAsAuthenticatedNativeRequestWithIdempotencyKeyAndNoBody() async throws {
        reset(status: 200, body: """
        {"ok":true,"booking":{"id":"bkg_1","checkoutStatus":"READY","paymentCollectedAt":null,"status":"IN_PROGRESS","sessionStep":"AFTER_PHOTOS"},"meta":{"mutated":true,"noOp":false,"reopened":true}}
        """)

        try await makeService().reopenCheckout(bookingId: "bkg_1")

        #expect(ProReopenCheckoutURLProtocol.capturedPath == "/api/v1/pro/bookings/bkg_1/checkout/reopen")
        #expect(ProReopenCheckoutURLProtocol.capturedMethod == "POST")
        #expect(ProReopenCheckoutURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(ProReopenCheckoutURLProtocol.capturedNativeHeader == "ios")
        // The route rejects a missing idempotency key — one must always be sent.
        #expect((ProReopenCheckoutURLProtocol.capturedIdempotencyKey ?? "").isEmpty == false)
        // No body — the reopen carries no parameters.
        #expect((ProReopenCheckoutURLProtocol.capturedBodyLength ?? 0) == 0)
    }

    @Test func surfacesStripeRefusalAsAPIError() async throws {
        reset(status: 409, body: """
        {"ok":false,"error":"This booking was paid by card, so it can't be reopened here. Issue a refund to return the money.","code":"CHECKOUT_REOPEN_STRIPE_REQUIRES_REFUND","retryable":false,"uiAction":"NONE","message":"A booking paid by Stripe card cannot be reopened; issue a refund instead."}
        """)

        await #expect(throws: APIError.self) {
            try await makeService().reopenCheckout(bookingId: "bkg_1")
        }
    }

    // MARK: - isManuallyClosed gate (decides whether the undo affordance shows)

    @Test func isManuallyClosedForCashPaid() {
        let checkout = ProSessionStateCheckout(
            status: "PAID", selectedPaymentMethod: "CASH", paymentCollectedAt: "2026-07-08T18:00:00.000Z")
        #expect(checkout.isManuallyClosed)
    }

    @Test func isManuallyClosedForWaivedWithNoMethod() {
        let checkout = ProSessionStateCheckout(
            status: "WAIVED", selectedPaymentMethod: nil, paymentCollectedAt: "2026-07-08T18:00:00.000Z")
        #expect(checkout.isManuallyClosed)
    }

    @Test func notManuallyClosedForStripeCard() {
        let checkout = ProSessionStateCheckout(
            status: "PAID", selectedPaymentMethod: "STRIPE_CARD", paymentCollectedAt: "2026-07-08T18:00:00.000Z")
        #expect(checkout.isManuallyClosed == false)
    }

    @Test func notManuallyClosedWhenNotClosed() {
        let checkout = ProSessionStateCheckout(
            status: "READY", selectedPaymentMethod: nil, paymentCollectedAt: nil)
        #expect(checkout.isManuallyClosed == false)
    }
}
