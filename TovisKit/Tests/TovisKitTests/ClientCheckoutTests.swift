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
        guard case let .link(href, _, label) = action else {
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
        guard case let .link(href, _, _) = action else {
            Issue.record("expected a link")
            return
        }
        #expect(href.absoluteString == "https://venmo.com/amara?txn=pay&amount=97.00")
    }

    /// The https URL never opens the Venmo app: venmo.com's
    /// apple-app-site-association does not claim a bare /<username>, and the
    /// 302→307 chain it serves ends at venmo://paycharge — a redirect into a
    /// custom scheme, which iOS will not follow. We must emit that scheme URL
    /// ourselves and open it directly.
    @Test func venmoEmitsAnAppSchemeUrlAlongsideTheWebUrl() throws {
        let action = try #require(
            buildPaymentDeepLink(methodKey: "venmo", handle: "@amara", amountDue: 72, note: "Tovis")
        )
        guard case let .link(_, appHref, _) = action else {
            Issue.record("expected a link")
            return
        }
        let app = try #require(appHref)
        #expect(app.scheme == "venmo")

        let components = try #require(URLComponents(url: app, resolvingAgainstBaseURL: false))
        #expect(components.host == "paycharge")
        let items = components.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "txn", value: "pay")))
        #expect(items.contains(URLQueryItem(name: "recipients", value: "amara")))
        #expect(items.contains(URLQueryItem(name: "amount", value: "72.00")))
        #expect(items.contains(URLQueryItem(name: "note", value: "Tovis")))
    }

    @Test func venmoOmitsTheNoteFromTheAppUrlWhenAbsent() throws {
        let action = try #require(
            buildPaymentDeepLink(methodKey: "venmo", handle: "amara", amountDue: 12, note: nil)
        )
        guard case let .link(_, appHref, _) = action else {
            Issue.record("expected a link")
            return
        }
        let app = try #require(appHref)
        #expect(app.absoluteString == "venmo://paycharge?txn=pay&recipients=amara&amount=12.00")
    }

    /// paypal.me's apple-app-site-association claims "/*", so the https URL is a
    /// genuine universal link — no custom-scheme escape hatch needed.
    @Test func paypalNeedsNoAppSchemeUrl() throws {
        let action = try #require(
            buildPaymentDeepLink(methodKey: "paypal", handle: "amara", amountDue: 72, note: nil)
        )
        guard case let .link(_, appHref, _) = action else {
            Issue.record("expected a link")
            return
        }
        #expect(appHref == nil)
    }

    @Test func paypalLocksAmountIntoThePath() throws {
        let action = try #require(
            buildPaymentDeepLink(methodKey: "paypal", handle: "amara", amountDue: 72, note: nil)
        )
        guard case let .link(href, _, label) = action else {
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
        guard case let .link(href, _, _) = action else {
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

// MARK: - Deposit credit (item 5 of the booking add-ons cluster, 2026-08-18)
//
// iOS used to quote platform credit — and the off-platform Venmo/Zelle
// deep-link amount — against the FULL bill, never subtracting a deposit
// already paid. A client who paid a $30 deposit toward a $100 bill would be
// told to send $100 again over Venmo, with no charge object afterward to
// correct it. These pin `CheckoutMoney.depositCreditApplied` against the same
// three states web's `deriveDepositCredit` distinguishes.

@Suite struct DepositCreditAppliedTests {
    @Test func paidUndisputedDepositCreditsTheHeldAmount() {
        let credit = CheckoutMoney.depositCreditApplied(
            depositStatus: "PAID", depositAmount: "30.00", depositRefundedCents: 0,
            depositDisputed: false, total: 100
        )
        #expect(credit == 30)
    }

    @Test func creditIsCappedAtTheTotalNeverNegativeAmountDue() {
        // The pro discounted the service after the deposit landed.
        let credit = CheckoutMoney.depositCreditApplied(
            depositStatus: "PAID", depositAmount: "80.00", depositRefundedCents: 0,
            depositDisputed: false, total: 50
        )
        #expect(credit == 50)
    }

    @Test func pendingOrFailedOrNoneDepositCreditsNothing() {
        for status in ["PENDING", "FAILED", "NONE", nil] {
            let credit = CheckoutMoney.depositCreditApplied(
                depositStatus: status, depositAmount: "30.00", depositRefundedCents: 0,
                depositDisputed: false, total: 100
            )
            #expect(credit == 0)
        }
    }

    /// A disputed deposit is money Stripe has already clawed back — it credits
    /// nothing even though `depositStatus` still reads PAID.
    @Test func disputedDepositCreditsNothingEvenWhilePaid() {
        let credit = CheckoutMoney.depositCreditApplied(
            depositStatus: "PAID", depositAmount: "30.00", depositRefundedCents: 0,
            depositDisputed: true, total: 100
        )
        #expect(credit == 0)
    }

    @Test func unparseableOrMissingAmountCreditsZeroNotNaN() {
        let credit = CheckoutMoney.depositCreditApplied(
            depositStatus: "PAID", depositAmount: nil, depositRefundedCents: 0,
            depositDisputed: false, total: 100
        )
        #expect(credit == 0)
    }

    // MARK: - Partial refunds (handoff item 32, 2026-08-18)
    //
    // `depositStatus` stays PAID through a PARTIAL refund — only
    // `depositRefundedCents` moves — so none of the tests above could tell a
    // fully-held deposit from a half-returned one. Web has always netted the
    // refund out (`deriveNetDepositHeldCents`); iOS had no column to net.

    @Test func partiallyRefundedDepositCreditsOnlyTheNetStillHeld() {
        // Web's own worked example: refund $20 of a $60 deposit → $40 credit.
        let credit = CheckoutMoney.depositCreditApplied(
            depositStatus: "PAID", depositAmount: "60.00", depositRefundedCents: 2000,
            depositDisputed: false, total: 100
        )
        #expect(credit == 40)
    }

    @Test func fullyRefundedDepositWhileStillMarkedPaidCreditsNothing() {
        // A refund that happens to land on the whole amount before the status
        // row catches up. Nothing is held, so nothing may be credited.
        let credit = CheckoutMoney.depositCreditApplied(
            depositStatus: "PAID", depositAmount: "60.00", depositRefundedCents: 6000,
            depositDisputed: false, total: 100
        )
        #expect(credit == 0)
    }

    @Test func refundBeyondTheDepositNeverCreditsANegative() {
        // Over-refunded (or a nonsense value): floors at 0, never a negative
        // credit that would INFLATE the amount due.
        let credit = CheckoutMoney.depositCreditApplied(
            depositStatus: "PAID", depositAmount: "60.00", depositRefundedCents: 9000,
            depositDisputed: false, total: 100
        )
        #expect(credit == 0)
    }

    @Test func refundIsNettedBeforeTheCapNotAfter() {
        // $80 deposit, $50 back, $40 bill. Netting first gives $30 (correct);
        // capping first and then subtracting would give $0 — the ordering this
        // pins. Also the case a "cap at total" shortcut gets wrong silently.
        let credit = CheckoutMoney.depositCreditApplied(
            depositStatus: "PAID", depositAmount: "80.00", depositRefundedCents: 5000,
            depositDisputed: false, total: 40
        )
        #expect(credit == 30)
    }

    @Test func partialRefundOnAPendingDepositStillCreditsNothing() {
        // The status gate runs first: money that never landed cannot be netted
        // into a credit no matter what the refund column says.
        let credit = CheckoutMoney.depositCreditApplied(
            depositStatus: "PENDING", depositAmount: "60.00", depositRefundedCents: 2000,
            depositDisputed: false, total: 100
        )
        #expect(credit == 0)
    }

    @Test func fractionalRefundCentsSurviveAsExactDecimals() {
        // 12.34 back off a 60.00 deposit = 47.66 exactly — no Double drift.
        let credit = CheckoutMoney.depositCreditApplied(
            depositStatus: "PAID", depositAmount: "60.00", depositRefundedCents: 1234,
            depositDisputed: false, total: 100
        )
        #expect(credit == Decimal(string: "47.66"))
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

// MARK: - Final-bill session start (web K10-A: the deposit credit)

/// The final bill's session can legitimately not exist: when a paid deposit
/// covers the whole total there is nothing to charge, so the server settles
/// checkout PAID and returns `sessionId: null` with `settledByDeposit: true`.
///
/// 🔴 `StripeCheckoutSession.sessionId` used to be a non-optional `String`, so
/// that null THREW during synthesized decoding and the client was shown
/// "Couldn't start checkout. Please try again." on a booking the server had
/// already marked PAID — a fully-paid client told their payment failed, on every
/// retry. These pin both branches and the pre-deploy server.

/// A SEPARATE transport for the session-start suite. `ClientCheckoutURLProtocol`
/// keeps its canned response in a static, and distinct @Suite types run in
/// parallel — sharing it let this suite's body leak into the confirm suite's
/// requests and vice versa. One static per suite, so neither can stomp the other.
final class CheckoutStartURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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

@Suite(.serialized) struct ClientCheckoutSessionStartTests {
    private func makeService() async -> CheckoutService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CheckoutStartURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.checkoutstart.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return CheckoutService(api: api)
    }

    private func reset(_ body: String) {
        CheckoutStartURLProtocol.responseBody = Data(body.utf8)
    }

    @Test func payableBillReturnsASessionToOpen() async throws {
        reset("""
        {"ok":true,"booking":{"id":"bkg_1","checkoutStatus":"READY","selectedPaymentMethod":"STRIPE_CARD","paymentProvider":"STRIPE","stripeCheckoutSessionId":"cs_1","stripePaymentIntentId":"pi_1","stripeCheckoutSessionStatus":"OPEN","stripePaymentStatus":"PROCESSING","stripeAmountTotal":20200,"stripeCurrency":"usd","tipAmount":"0.00","totalAmount":"242.00"},"stripeCheckout":{"sessionId":"cs_1","url":"https://checkout.stripe.com/c/pay/cs_1"},"settledByDeposit":false,"depositCreditCents":4000}
        """)

        let start = try await makeService().createCheckoutSession(bookingId: "bkg_1", tipAmount: nil)

        guard case let .session(stripeSession) = start else {
            Issue.record("expected a payable session")
            return
        }
        #expect(stripeSession.sessionId == "cs_1")
        #expect(stripeSession.url == "https://checkout.stripe.com/c/pay/cs_1")
    }

    /// The bug, at the wire. A null id must decode and report "nothing to pay".
    @Test func depositCoveringTheBillSettlesInsteadOfThrowing() async throws {
        reset("""
        {"ok":true,"booking":{"id":"bkg_1","checkoutStatus":"PAID","selectedPaymentMethod":null,"paymentProvider":"MANUAL","stripeCheckoutSessionId":null,"stripePaymentIntentId":null,"stripeCheckoutSessionStatus":null,"stripePaymentStatus":null,"stripeAmountTotal":null,"stripeCurrency":null,"tipAmount":"0.00","totalAmount":"242.00"},"stripeCheckout":{"sessionId":null,"url":null},"settledByDeposit":true,"depositCreditCents":24200}
        """)

        let start = try await makeService().createCheckoutSession(bookingId: "bkg_1", tipAmount: nil)

        guard case let .settledByDeposit(creditCents) = start else {
            Issue.record("expected the settled branch, not a session")
            return
        }
        #expect(creditCents == 24200)
    }

    /// Belt-and-braces: even without the flag, a missing session id can never be
    /// mistaken for something the app should try to open.
    @Test func aNullSessionIdSettlesEvenWhenTheFlagIsAbsent() async throws {
        reset("""
        {"ok":true,"booking":{"id":"bkg_1","checkoutStatus":"PAID","tipAmount":"0.00","totalAmount":"242.00"},"stripeCheckout":{"sessionId":null,"url":null}}
        """)

        let start = try await makeService().createCheckoutSession(bookingId: "bkg_1", tipAmount: nil)

        guard case .settledByDeposit = start else {
            Issue.record("expected the settled branch")
            return
        }
    }

    /// A pre-K10-A server sends neither new field. That must still decode and
    /// still open the session — the deploy is not atomic across web and device.
    @Test func preDeployServerWithoutTheNewFieldsStillOpensItsSession() async throws {
        reset("""
        {"ok":true,"booking":{"id":"bkg_1","checkoutStatus":"READY","tipAmount":"0.00","totalAmount":"242.00"},"stripeCheckout":{"sessionId":"cs_old","url":"https://checkout.stripe.com/c/pay/cs_old"}}
        """)

        let start = try await makeService().createCheckoutSession(bookingId: "bkg_1", tipAmount: nil)

        guard case let .session(stripeSession) = start else {
            Issue.record("expected a payable session from a pre-deploy server")
            return
        }
        #expect(stripeSession.sessionId == "cs_old")
    }
}
