import Foundation
import Testing
@testable import TovisKit

// Proves the client Payment-methods surface hits the right routes, sends the
// right bodies, and decodes each response:
//   • list()                    → GET    /client/payment-methods       → { ok, paymentMethods }
//   • createSetupIntent()        → POST   /client/payment-methods/setup-intent → { ok, clientSecret, … , publishableKey }
//   • confirmCard(setupIntentId:)→ POST   /client/payment-methods       body { setupIntentId } → { ok, paymentMethod }
//   • remove(id:)                → DELETE /client/payment-methods/{id}
// Mirrors web lib/dto/clientPaymentMethods.ts + the ClientPaymentMethodsSettings flow.

/// Records the outgoing request (path, method, body) and serves a canned envelope.
final class PaymentMethodsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        // URLProtocol strips httpBody for a streamed body — read the stream.
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            Self.capturedBody = data
        } else {
            Self.capturedBody = request.httpBody
        }

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

@Suite(.serialized) struct PaymentMethodsServiceTests {
    private func makeService() async -> PaymentMethodsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PaymentMethodsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.paymentmethods.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return PaymentMethodsService(api: api)
    }

    private func reset() {
        PaymentMethodsURLProtocol.capturedPath = nil
        PaymentMethodsURLProtocol.capturedMethod = nil
        PaymentMethodsURLProtocol.capturedBody = nil
        PaymentMethodsURLProtocol.status = 200
        PaymentMethodsURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    // MARK: - list()

    @Test func listGetsAndDecodes() async throws {
        reset()
        PaymentMethodsURLProtocol.responseBody = Data("""
        {"ok":true,"paymentMethods":[
          {"id":"pm_1","brand":"visa","last4":"4242","expMonth":12,"expYear":2030,"isDefault":true,"createdAt":"2026-07-03T00:00:00.000Z"},
          {"id":"pm_2","brand":null,"last4":null,"expMonth":null,"expYear":null,"isDefault":false,"createdAt":"2026-07-01T00:00:00.000Z"}
        ]}
        """.utf8)

        let cards = try await makeService().list()

        #expect(PaymentMethodsURLProtocol.capturedPath == "/api/v1/client/payment-methods")
        #expect(PaymentMethodsURLProtocol.capturedMethod == "GET")
        #expect(cards.count == 2)

        let first = try #require(cards.first)
        #expect(first.id == "pm_1")
        #expect(first.brand == "visa")
        #expect(first.last4 == "4242")
        #expect(first.expMonth == 12)
        #expect(first.expYear == 2030)
        #expect(first.isDefault == true)

        let pending = cards[1]
        #expect(pending.brand == nil)
        #expect(pending.last4 == nil)
        #expect(pending.isDefault == false)
    }

    @Test func listDecodesEmpty() async throws {
        reset()
        PaymentMethodsURLProtocol.responseBody = Data("{\"ok\":true,\"paymentMethods\":[]}".utf8)
        let cards = try await makeService().list()
        #expect(cards.isEmpty)
    }

    // MARK: - createSetupIntent()

    @Test func setupIntentPostsAndDecodesPublishableKey() async throws {
        reset()
        PaymentMethodsURLProtocol.responseBody = Data("""
        {"ok":true,"clientSecret":"seti_abc_secret","setupIntentId":"seti_abc","customerId":"cus_1","publishableKey":"pk_test_123"}
        """.utf8)

        let intent = try await makeService().createSetupIntent()

        #expect(PaymentMethodsURLProtocol.capturedPath == "/api/v1/client/payment-methods/setup-intent")
        #expect(PaymentMethodsURLProtocol.capturedMethod == "POST")
        #expect(intent.clientSecret == "seti_abc_secret")
        #expect(intent.setupIntentId == "seti_abc")
        #expect(intent.customerId == "cus_1")
        #expect(intent.publishableKey == "pk_test_123")
    }

    @Test func setupIntentToleratesMissingPublishableKey() async throws {
        // An older (pre-paired-PR) server omits the additive field → nil, not a
        // decode failure.
        reset()
        PaymentMethodsURLProtocol.responseBody = Data("""
        {"ok":true,"clientSecret":"seti_abc_secret","setupIntentId":"seti_abc","customerId":"cus_1"}
        """.utf8)

        let intent = try await makeService().createSetupIntent()
        #expect(intent.publishableKey == nil)
    }

    // MARK: - confirmCard()

    @Test func confirmCardPostsSetupIntentIdAndDecodes() async throws {
        reset()
        PaymentMethodsURLProtocol.responseBody = Data("""
        {"ok":true,"paymentMethod":{"id":"pm_new","brand":"mastercard","last4":"4444","expMonth":1,"expYear":2031,"isDefault":true,"createdAt":"2026-07-11T00:00:00.000Z"}}
        """.utf8)

        let card = try await makeService().confirmCard(setupIntentId: "seti_abc")

        #expect(PaymentMethodsURLProtocol.capturedPath == "/api/v1/client/payment-methods")
        #expect(PaymentMethodsURLProtocol.capturedMethod == "POST")

        let body = try #require(PaymentMethodsURLProtocol.capturedBody)
        let decoded = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["setupIntentId"] as? String == "seti_abc")

        #expect(card.id == "pm_new")
        #expect(card.brand == "mastercard")
        #expect(card.isDefault == true)
    }

    // MARK: - remove()

    @Test func removeDeletesTheCard() async throws {
        reset()
        PaymentMethodsURLProtocol.responseBody = Data("{\"ok\":true,\"removedId\":\"pm_1\"}".utf8)

        try await makeService().remove(id: "pm_1")

        #expect(PaymentMethodsURLProtocol.capturedPath == "/api/v1/client/payment-methods/pm_1")
        #expect(PaymentMethodsURLProtocol.capturedMethod == "DELETE")
    }

    // MARK: - dark flag (404)

    @Test func listThrowsServer404WhenDark() async throws {
        reset()
        PaymentMethodsURLProtocol.status = 404
        PaymentMethodsURLProtocol.responseBody = Data("{\"ok\":false,\"error\":\"Not found.\"}".utf8)

        do {
            _ = try await makeService().list()
            Issue.record("expected list() to throw a 404 while the flag is dark")
        } catch let error as APIError {
            guard case let .server(status, _, _) = error else {
                Issue.record("expected APIError.server, got \(error)")
                return
            }
            #expect(status == 404)
        }
    }
}
