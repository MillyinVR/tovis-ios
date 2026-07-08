import Foundation
import Testing
@testable import TovisKit

// Proves ProBookingService.confirmPayment(bookingId:) POSTs the dedicated
// confirm-payment route as an authenticated native request with an idempotency-key
// header and no body, and decodes the response — including the coupled next-appointment
// ids and a checkoutStatus string the app doesn't special-case.

/// Serves a canned confirm-payment envelope and records the outgoing request.
final class ProConfirmPaymentURLProtocol: URLProtocol {
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

@Suite(.serialized) struct ProConfirmPaymentTests {
    private func makeService() async -> ProBookingService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProConfirmPaymentURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.confirmpayment.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProBookingService(api: api)
    }

    private func reset(_ body: String) {
        ProConfirmPaymentURLProtocol.capturedPath = nil
        ProConfirmPaymentURLProtocol.capturedMethod = nil
        ProConfirmPaymentURLProtocol.capturedAuthHeader = nil
        ProConfirmPaymentURLProtocol.capturedNativeHeader = nil
        ProConfirmPaymentURLProtocol.capturedIdempotencyKey = nil
        ProConfirmPaymentURLProtocol.capturedBodyLength = nil
        ProConfirmPaymentURLProtocol.status = 200
        ProConfirmPaymentURLProtocol.responseBody = Data(body.utf8)
    }

    @Test func postsConfirmPaymentAsAuthenticatedNativeRequestWithIdempotencyKey() async throws {
        reset("""
        {"ok":true,"booking":{"id":"bkg_1","checkoutStatus":"PAID","paymentCollectedAt":"2026-07-08T18:00:00.000Z","status":"COMPLETED","sessionStep":"DONE"},"meta":{"mutated":true,"noOp":false,"completedBooking":true,"approvedNextAppointmentBookingIds":["bkg_2"]}}
        """)

        let result = try await makeService().confirmPayment(bookingId: "bkg_1")

        #expect(ProConfirmPaymentURLProtocol.capturedPath == "/api/v1/pro/bookings/bkg_1/checkout/confirm-payment")
        #expect(ProConfirmPaymentURLProtocol.capturedMethod == "POST")
        #expect(ProConfirmPaymentURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(ProConfirmPaymentURLProtocol.capturedNativeHeader == "ios")
        // The route rejects a missing idempotency key — one must always be sent.
        #expect((ProConfirmPaymentURLProtocol.capturedIdempotencyKey ?? "").isEmpty == false)
        // No body — the payment method was recorded at client checkout.
        #expect((ProConfirmPaymentURLProtocol.capturedBodyLength ?? 0) == 0)

        #expect(result.booking.checkoutStatus == "PAID")
        #expect(result.booking.paymentCollectedAt != nil)
        #expect(result.meta.completedBooking)
        #expect(result.meta.approvedNextAppointmentBookingIds == ["bkg_2"])
        #expect(result.meta.approvedANextAppointment)
    }

    @Test func decodesNoCoupledNextAppointment() async throws {
        reset("""
        {"ok":true,"booking":{"id":"bkg_1","checkoutStatus":"PAID","paymentCollectedAt":null,"status":"IN_PROGRESS","sessionStep":null},"meta":{"mutated":true,"noOp":false,"completedBooking":false,"approvedNextAppointmentBookingIds":[]}}
        """)

        let result = try await makeService().confirmPayment(bookingId: "bkg_1")

        #expect(result.booking.paymentCollectedAt == nil)
        #expect(result.booking.sessionStep == nil)
        #expect(result.meta.approvedNextAppointmentBookingIds.isEmpty)
        #expect(result.meta.approvedANextAppointment == false)
    }
}
