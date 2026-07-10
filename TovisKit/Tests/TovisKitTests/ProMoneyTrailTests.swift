import Foundation
import Testing
@testable import TovisKit

// Proves ProBookingService.moneyTrail(bookingId:) GETs the shared
// `/bookings/{id}/money-trail` route (NOT a `/pro` route) as an authenticated
// native request with no body, and decodes the full `{ ok, trail }` envelope —
// nested charges/fees/refunds, the summary, and the capability flags — plus a
// minimal all-null trail (older/empty bookings still decode).

/// Serves a canned money-trail envelope and records the outgoing request.
final class ProMoneyTrailURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedAuthHeader: String?
    nonisolated(unsafe) static var capturedNativeHeader: String?
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

@Suite(.serialized) struct ProMoneyTrailTests {
    private func makeService() async -> ProBookingService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProMoneyTrailURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.moneytrail.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProBookingService(api: api)
    }

    private func reset(_ body: String) {
        ProMoneyTrailURLProtocol.capturedPath = nil
        ProMoneyTrailURLProtocol.capturedMethod = nil
        ProMoneyTrailURLProtocol.capturedAuthHeader = nil
        ProMoneyTrailURLProtocol.capturedNativeHeader = nil
        ProMoneyTrailURLProtocol.capturedBodyLength = nil
        ProMoneyTrailURLProtocol.status = 200
        ProMoneyTrailURLProtocol.responseBody = Data(body.utf8)
    }

    @Test func getsMoneyTrailAsAuthenticatedNativeRequestAndDecodesFully() async throws {
        reset("""
        {"ok":true,"trail":{
          "bookingId":"bkg_1","currency":"usd","paymentProvider":"STRIPE",
          "bill":{"totalCents":12000,"serviceSubtotalCents":10000,"tipCents":1500,"taxCents":500,"discountCents":null,"checkoutStatus":"PAID","selectedPaymentMethod":"STRIPE_CARD","collectedAt":"2026-07-08T18:00:00.000Z"},
          "finalCharge":{"status":"SUCCEEDED","capturedCents":12000,"applicationFeeCents":360,"paidAt":"2026-07-08T18:00:00.000Z"},
          "deposit":{"status":"PAID","amountCents":3000,"paidAt":"2026-07-01T12:00:00.000Z","creditedAt":"2026-07-08T18:00:00.000Z","refundedCents":0},
          "discoveryFee":{"amountCents":500,"refundedAt":null},
          "noShowFee":{"status":"FAILED","reason":"NO_SHOW","amountCents":2500,"chargedAt":null,"markedAt":"2026-07-02T09:00:00.000Z"},
          "refunds":[{"id":"ref_1","amountCents":2000,"currency":"usd","status":"SUCCEEDED","trigger":"DISCRETIONARY","reason":"service issue","initiatedByRole":"PRO","failureMessage":null,"createdAt":"2026-07-09T10:00:00.000Z"}],
          "summary":{"capturedCents":12000,"refundedCents":2000,"pendingRefundCents":0,"netCents":10000},
          "capabilities":{"canRefund":true,"refundableRemainingCents":10000,"canWaiveNoShowFee":true}
        }}
        """)

        let trail = try await makeService().moneyTrail(bookingId: "bkg_1")

        #expect(ProMoneyTrailURLProtocol.capturedPath == "/api/v1/bookings/bkg_1/money-trail")
        #expect(ProMoneyTrailURLProtocol.capturedMethod == "GET")
        #expect(ProMoneyTrailURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(ProMoneyTrailURLProtocol.capturedNativeHeader == "ios")
        #expect((ProMoneyTrailURLProtocol.capturedBodyLength ?? 0) == 0)

        #expect(trail.bookingId == "bkg_1")
        #expect(trail.currency == "usd")
        #expect(trail.paymentProvider == "STRIPE")
        #expect(trail.bill.totalCents == 12000)
        #expect(trail.bill.discountCents == nil)
        #expect(trail.bill.checkoutStatus == "PAID")
        #expect(trail.finalCharge?.status == "SUCCEEDED")
        #expect(trail.finalCharge?.capturedCents == 12000)
        #expect(trail.deposit?.status == "PAID")
        #expect(trail.deposit?.refundedCents == 0)
        #expect(trail.discoveryFee?.amountCents == 500)
        #expect(trail.discoveryFee?.refundedAt == nil)
        #expect(trail.noShowFee?.status == "FAILED")
        #expect(trail.noShowFee?.reason == "NO_SHOW")
        #expect(trail.refunds.count == 1)
        #expect(trail.refunds.first?.id == "ref_1")
        #expect(trail.refunds.first?.trigger == "DISCRETIONARY")
        #expect(trail.refunds.first?.initiatedByRole == "PRO")
        #expect(trail.summary.netCents == 10000)
        #expect(trail.capabilities.canRefund)
        #expect(trail.capabilities.refundableRemainingCents == 10000)
        #expect(trail.capabilities.canWaiveNoShowFee)
    }

    @Test func decodesMinimalAllNullTrail() async throws {
        reset("""
        {"ok":true,"trail":{
          "bookingId":"bkg_2","currency":"usd","paymentProvider":"MANUAL",
          "bill":{"totalCents":null,"serviceSubtotalCents":null,"tipCents":null,"taxCents":null,"discountCents":null,"checkoutStatus":"NOT_READY","selectedPaymentMethod":null,"collectedAt":null},
          "finalCharge":null,"deposit":null,"discoveryFee":null,"noShowFee":null,
          "refunds":[],
          "summary":{"capturedCents":0,"refundedCents":0,"pendingRefundCents":0,"netCents":0},
          "capabilities":{"canRefund":false,"refundableRemainingCents":0,"canWaiveNoShowFee":false}
        }}
        """)

        let trail = try await makeService().moneyTrail(bookingId: "bkg_2")

        #expect(trail.paymentProvider == "MANUAL")
        #expect(trail.bill.totalCents == nil)
        #expect(trail.bill.selectedPaymentMethod == nil)
        #expect(trail.finalCharge == nil)
        #expect(trail.deposit == nil)
        #expect(trail.discoveryFee == nil)
        #expect(trail.noShowFee == nil)
        #expect(trail.refunds.isEmpty)
        #expect(trail.summary.capturedCents == 0)
        #expect(trail.capabilities.canRefund == false)
    }
}
