import Foundation
import Testing
@testable import TovisKit

// Covers the native client checkout money path: the off-platform deep-link/copy
// builder, the tip + live-total math (CHK-tip-live), the non-card confirm call,
// and decoding the pro's payment options off the booking DTO. Amounts are real
// money, so these are the guardrail against silent drift from web.

// MARK: - Deep-link builder

@Suite struct PaymentDeepLinkTests {
    @Test func venmoBuildsUniversalLinkWithAmountAndNote() throws {
        let action = try #require(
            buildPaymentDeepLink(methodKey: "venmo", handle: "@amara", amountDue: 72, note: "Tovis")
        )
        guard case let .link(href, label) = action else {
            Issue.record("expected a link")
            return
        }
        let url = href.absoluteString
        #expect(url.hasPrefix("https://venmo.com/amara?"))
        #expect(url.contains("txn=pay"))
        #expect(url.contains("amount=72.00"))
        #expect(url.contains("note=Tovis"))
        #expect(label == "Pay $72.00 with Venmo")
    }

    @Test func venmoStripsLeadingAtAndUsesLiveTippedAmount() throws {
        let action = try #require(
            buildPaymentDeepLink(methodKey: "venmo", handle: "@amara", amountDue: Decimal(string: "97.00")!, note: nil)
        )
        guard case let .link(href, _) = action else {
            Issue.record("expected a link")
            return
        }
        #expect(href.absoluteString == "https://venmo.com/amara?txn=pay&amount=97.00")
    }

    @Test func paypalLocksAmountIntoThePath() throws {
        let action = try #require(
            buildPaymentDeepLink(methodKey: "paypal", handle: "amara", amountDue: 72, note: nil)
        )
        guard case let .link(href, label) = action else {
            Issue.record("expected a link")
            return
        }
        #expect(href.absoluteString == "https://paypal.me/amara/72.00")
        #expect(label == "Pay $72.00 with PayPal")
    }

    @Test func paypalExtractsUsernameFromAFullUrl() throws {
        let action = try #require(
            buildPaymentDeepLink(methodKey: "paypal", handle: "https://paypal.me/amara", amountDue: 50, note: nil)
        )
        guard case let .link(href, _) = action else {
            Issue.record("expected a link")
            return
        }
        #expect(href.absoluteString == "https://paypal.me/amara/50.00")
    }

    @Test func zelleAndAppleCashReturnCopyWithHandleAndAmount() throws {
        let zelle = try #require(
            buildPaymentDeepLink(methodKey: "zelle", handle: "555-1212", amountDue: 72, note: nil)
        )
        guard case let .copy(handle, amount, instruction) = zelle else {
            Issue.record("expected copy")
            return
        }
        #expect(handle == "555-1212")
        #expect(amount == "72.00")
        #expect(instruction == "Open Zelle in your bank app and send $72.00 to 555-1212.")

        let appleCash = try #require(
            buildPaymentDeepLink(methodKey: "apple_cash", handle: "a@b.com", amountDue: 40, note: nil)
        )
        guard case let .copy(_, _, appleInstruction) = appleCash else {
            Issue.record("expected copy")
            return
        }
        #expect(appleInstruction == "Open Messages or Wallet and send $40.00 to a@b.com with Apple Cash.")
    }

    @Test func noOffPlatformActionForCashCardRailsOrStripe() {
        for key in ["cash", "card_on_file", "tap_to_pay", "apple_pay", "stripe_card", "unknown"] {
            #expect(buildPaymentDeepLink(methodKey: key, handle: "x", amountDue: 72, note: nil) == nil)
        }
    }

    @Test func nilWhenHandleMissingOrAmountNonPositive() {
        #expect(buildPaymentDeepLink(methodKey: "venmo", handle: nil, amountDue: 72, note: nil) == nil)
        #expect(buildPaymentDeepLink(methodKey: "venmo", handle: "  ", amountDue: 72, note: nil) == nil)
        #expect(buildPaymentDeepLink(methodKey: "venmo", handle: "@amara", amountDue: 0, note: nil) == nil)
    }
}

// MARK: - Tip + total math

@Suite struct CheckoutMoneyTests {
    @Test func tipIsAPercentOfServicesOnly() {
        #expect(CheckoutMoney.tip(serviceSubtotal: 60, percent: 20) == Decimal(string: "12.00"))
        #expect(CheckoutMoney.tip(serviceSubtotal: 0, percent: 20) == 0)
        #expect(CheckoutMoney.tip(serviceSubtotal: 60, percent: 0) == 0)
    }

    @Test func liveTotalSumsAllComponents() {
        // $60 service + $25 products + $12 tip (20%) + $0 tax − $0 discount = $97.
        let total = CheckoutMoney.liveTotal(
            serviceSubtotal: 60, productSubtotal: 25,
            tip: CheckoutMoney.tip(serviceSubtotal: 60, percent: 20),
            tax: 0, discount: 0
        )
        #expect(total == Decimal(string: "97"))
        #expect(CheckoutMoney.fixed2(total) == "97.00")
    }

    @Test func fixed2AlwaysEmitsTwoDecimalsWithoutGrouping() {
        #expect(CheckoutMoney.fixed2(72) == "72.00")
        #expect(CheckoutMoney.fixed2(Decimal(string: "72.5")!) == "72.50")
        #expect(CheckoutMoney.fixed2(1234) == "1234.00")
    }

    @Test func amountParsesWireStringsAndDefaultsToZero() {
        #expect(CheckoutMoney.amount("120.00") == 120)
        #expect(CheckoutMoney.amount(nil) == 0)
        #expect(CheckoutMoney.amount("") == 0)
    }
}

// MARK: - Non-card confirm call

/// Serves a canned checkout-confirm envelope and records the outgoing request.
final class ClientCheckoutURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedIdempotencyKey: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedIdempotencyKey = request.value(forHTTPHeaderField: "idempotency-key")
        // URLProtocol strips httpBody into httpBodyStream; read whichever is set.
        Self.capturedBody = request.httpBody ?? request.bodyStreamData()

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

@Suite(.serialized) struct ClientCheckoutConfirmTests {
    private func makeService() async -> CheckoutService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientCheckoutURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.clientcheckout.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return CheckoutService(api: api)
    }

    private func reset(_ body: String) {
        ClientCheckoutURLProtocol.capturedPath = nil
        ClientCheckoutURLProtocol.capturedMethod = nil
        ClientCheckoutURLProtocol.capturedIdempotencyKey = nil
        ClientCheckoutURLProtocol.capturedBody = nil
        ClientCheckoutURLProtocol.responseBody = Data(body.utf8)
    }

    @Test func confirmPostsCheckoutWithTipMethodAndConfirmFlag() async throws {
        reset("""
        {"ok":true,"booking":{"id":"bkg_1","checkoutStatus":"AWAITING_CONFIRMATION","selectedPaymentMethod":"VENMO","tipAmount":"12.00","totalAmount":"97.00","paymentAuthorizedAt":"2026-07-09T18:00:00.000Z","paymentCollectedAt":null},"meta":{"mutated":true,"noOp":false}}
        """)

        let result = try await makeService().confirmCheckout(
            bookingId: "bkg_1", tipAmount: "12.00",
            selectedPaymentMethod: "VENMO", confirmPayment: true
        )

        #expect(ClientCheckoutURLProtocol.capturedPath == "/api/v1/client/bookings/bkg_1/checkout")
        #expect(ClientCheckoutURLProtocol.capturedMethod == "POST")
        #expect((ClientCheckoutURLProtocol.capturedIdempotencyKey ?? "").isEmpty == false)

        let body = try #require(ClientCheckoutURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["tipAmount"] as? String == "12.00")
        #expect(json["selectedPaymentMethod"] as? String == "VENMO")
        #expect(json["confirmPayment"] as? Bool == true)

        // Unverifiable off-platform → AWAITING_CONFIRMATION, not collected yet.
        #expect(result.booking.checkoutStatus == "AWAITING_CONFIRMATION")
        #expect(result.booking.paymentCollectedAt == nil)
    }

    @Test func cardRailConfirmClosesOutAsPaid() async throws {
        reset("""
        {"ok":true,"booking":{"id":"bkg_1","checkoutStatus":"PAID","selectedPaymentMethod":"CARD_ON_FILE","tipAmount":"0.00","totalAmount":"60.00","paymentAuthorizedAt":"2026-07-09T18:00:00.000Z","paymentCollectedAt":"2026-07-09T18:00:00.000Z"},"meta":{"mutated":true,"noOp":false}}
        """)

        let result = try await makeService().confirmCheckout(
            bookingId: "bkg_1", tipAmount: "0.00",
            selectedPaymentMethod: "CARD_ON_FILE", confirmPayment: true
        )

        #expect(result.booking.checkoutStatus == "PAID")
        #expect(result.booking.paymentCollectedAt != nil)
    }

    @Test func saveTipSendsConfirmFalseAndOmitsNilMethod() async throws {
        reset("""
        {"ok":true,"booking":{"id":"bkg_1","checkoutStatus":"READY","selectedPaymentMethod":null,"tipAmount":"15.00","totalAmount":"75.00","paymentAuthorizedAt":null,"paymentCollectedAt":null},"meta":{"mutated":true,"noOp":false}}
        """)

        _ = try await makeService().confirmCheckout(
            bookingId: "bkg_1", tipAmount: "15.00",
            selectedPaymentMethod: nil, confirmPayment: false
        )

        let body = try #require(ClientCheckoutURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["confirmPayment"] as? Bool == false)
        #expect(json["tipAmount"] as? String == "15.00")
        // nil optional is omitted so the server reads the method as "unchanged".
        #expect(json["selectedPaymentMethod"] == nil)
    }
}

// MARK: - Payment options decoding

@Suite struct ClientBookingPaymentOptionsDecodingTests {
    @Test func decodesMethodsHandlesTipConfigAndNote() throws {
        let json = """
        {
          "methods": [
            { "key": "cash", "label": "Cash", "handle": null },
            { "key": "venmo", "label": "Venmo", "handle": "@amara" }
          ],
          "tipsEnabled": true,
          "allowCustomTip": false,
          "tipSuggestions": [18, 20, 25],
          "paymentNote": "Zelle preferred",
          "collectPaymentAt": "AFTER_SERVICE"
        }
        """
        let options = try JSONDecoder().decode(
            ClientBookingPaymentOptions.self, from: Data(json.utf8)
        )

        #expect(options.methods.count == 2)
        #expect(options.methods[0].handle == nil)
        #expect(options.methods[1].key == "venmo")
        #expect(options.methods[1].handle == "@amara")
        #expect(options.tipsEnabled)
        #expect(options.allowCustomTip == false)
        #expect(options.tipSuggestions == [18, 20, 25])
        #expect(options.paymentNote == "Zelle preferred")
        #expect(options.collectPaymentAt == "AFTER_SERVICE")
    }
}

// MARK: - Save checkout products (§5 A3-prod)

/// A dedicated capturing URLProtocol for the products suite. It has its OWN
/// static storage so it never races the `ClientCheckoutURLProtocol` the confirm
/// suite uses — different @Suites run in parallel and would otherwise clobber a
/// shared mock's response body.
final class CheckoutProductsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedIdempotencyKey: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedIdempotencyKey = request.value(forHTTPHeaderField: "idempotency-key")
        Self.capturedBody = request.httpBody ?? request.bodyStreamData()

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

@Suite(.serialized) struct ClientCheckoutProductsTests {
    private func makeService() async -> CheckoutService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CheckoutProductsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.checkoutproducts.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return CheckoutService(api: api)
    }

    private func reset(_ body: String) {
        CheckoutProductsURLProtocol.capturedPath = nil
        CheckoutProductsURLProtocol.capturedMethod = nil
        CheckoutProductsURLProtocol.capturedIdempotencyKey = nil
        CheckoutProductsURLProtocol.capturedBody = nil
        CheckoutProductsURLProtocol.responseBody = Data(body.utf8)
    }

    private static let okResponse = """
    {"ok":true,"booking":{"id":"bkg_1","checkoutStatus":"READY","serviceSubtotalSnapshot":"100.00","productSubtotalSnapshot":"56.00","subtotalSnapshot":"156.00","tipAmount":"0.00","taxAmount":"0.00","discountAmount":"0.00","totalAmount":"156.00","paymentAuthorizedAt":null,"paymentCollectedAt":null},"selectedProducts":[{"recommendationId":"rp_2","productId":"prod_9","quantity":2,"unitPrice":"28.00","lineTotal":"56.00"}],"meta":{"mutated":true,"noOp":false}}
    """

    @Test func postsSelectionItemsWithIdempotencyKeyAndDecodesResponse() async throws {
        reset(Self.okResponse)

        let result = try await makeService().saveCheckoutProducts(
            bookingId: "bkg_1",
            items: [CheckoutProductLineInput(
                recommendationId: "rp_2", productId: "prod_9", quantity: 2)]
        )

        #expect(CheckoutProductsURLProtocol.capturedPath == "/api/v1/client/bookings/bkg_1/checkout/products")
        #expect(CheckoutProductsURLProtocol.capturedMethod == "POST")
        #expect((CheckoutProductsURLProtocol.capturedIdempotencyKey ?? "").isEmpty == false)

        let body = try #require(CheckoutProductsURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let items = try #require(json["items"] as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items[0]["recommendationId"] as? String == "rp_2")
        #expect(items[0]["productId"] as? String == "prod_9")
        #expect(items[0]["quantity"] as? Int == 2)

        #expect(result.booking.productSubtotalSnapshot == "56.00")
        #expect(result.selectedProducts.first?.lineTotal == "56.00")
    }

    @Test func emptyItemsClearsTheSelection() async throws {
        reset("""
        {"ok":true,"booking":{"id":"bkg_1","checkoutStatus":"READY","serviceSubtotalSnapshot":"100.00","productSubtotalSnapshot":"0.00","subtotalSnapshot":"100.00","tipAmount":"0.00","taxAmount":"0.00","discountAmount":"0.00","totalAmount":"100.00","paymentAuthorizedAt":null,"paymentCollectedAt":null},"selectedProducts":[],"meta":{"mutated":true,"noOp":false}}
        """)

        let result = try await makeService().saveCheckoutProducts(bookingId: "bkg_1", items: [])

        let body = try #require(CheckoutProductsURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["items"] as? [[String: Any]])?.isEmpty == true)
        #expect(result.selectedProducts.isEmpty)
    }

    @Test func idempotencyKeyTracksTheSelection() async throws {
        // The iterative selection derives the key's nonce from the lines: an
        // identical selection dedupes (same key in the bucket) while a changed
        // selection gets a fresh key — mirrors the web nonce contract.
        let a = [CheckoutProductLineInput(recommendationId: "rp_2", productId: "prod_9", quantity: 2)]
        let b = [CheckoutProductLineInput(recommendationId: "rp_2", productId: "prod_9", quantity: 3)]

        reset(Self.okResponse)
        _ = try await makeService().saveCheckoutProducts(bookingId: "bkg_1", items: a)
        let key1 = CheckoutProductsURLProtocol.capturedIdempotencyKey

        reset(Self.okResponse)
        _ = try await makeService().saveCheckoutProducts(bookingId: "bkg_1", items: a)
        let key1Again = CheckoutProductsURLProtocol.capturedIdempotencyKey

        reset(Self.okResponse)
        _ = try await makeService().saveCheckoutProducts(bookingId: "bkg_1", items: b)
        let key2 = CheckoutProductsURLProtocol.capturedIdempotencyKey

        #expect(key1 == key1Again)
        #expect(key1 != key2)
    }
}
