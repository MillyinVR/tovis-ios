import Foundation
import Testing
@testable import TovisKit

// Proves the pro referral-REWARD config methods hit the right routes with the
// right verbs and bodies (existing web routes — an iOS-only port):
//   • rewardSettings       → GET  /api/v1/pro/settings/referral-rewards → decodes
//                            the config, including the credit amount that arrives
//                            as a Prisma Decimal STRING ("12.50") and RECOGNITION's
//                            null discount/credit → nil
//   • updateRewardSettings → PATCH the same route as JSON; the credit goes out as a
//                            NUMBER (the route rejects a string), the discount as an
//                            integer, and only the fields set on the patch are sent
//                            (nil optionals dropped, so the other tier's stored value
//                            is left untouched)

/// Records the outgoing request and serves a canned envelope.
final class ProReferralRewardURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedBody = request.httpBody ?? request.referralBodyStreamData()

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
    /// URLSession moves a PATCH body onto `httpBodyStream`; drain it for assertions.
    func referralBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ProReferralRewardSettingsTests {
    private func makeService() async -> ProReferralsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProReferralRewardURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.referralrewards.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProReferralsService(api: api)
    }

    private func reset(response: String) {
        ProReferralRewardURLProtocol.capturedPath = nil
        ProReferralRewardURLProtocol.capturedMethod = nil
        ProReferralRewardURLProtocol.capturedBody = nil
        ProReferralRewardURLProtocol.responseBody = Data(response.utf8)
    }

    /// Parse the captured JSON body into a dictionary for type-aware assertions.
    private func bodyObject() throws -> [String: Any] {
        let body = try #require(ProReferralRewardURLProtocol.capturedBody)
        let object = try JSONSerialization.jsonObject(with: body)
        return try #require(object as? [String: Any])
    }

    @Test func rewardSettingsDecodesCreditDecimalString() async throws {
        // Prisma serializes the Decimal credit as a JSON string.
        reset(response: """
        {
          "ok": true,
          "settings": {
            "referralRewardEnabled": true,
            "referralRewardTier": "CREDIT",
            "referralDiscountPercent": null,
            "referralCreditAmount": "12.50"
          }
        }
        """)

        let settings = try await makeService().rewardSettings()

        #expect(ProReferralRewardURLProtocol.capturedPath == "/api/v1/pro/settings/referral-rewards")
        #expect(ProReferralRewardURLProtocol.capturedMethod == "GET")

        #expect(settings.enabled)
        #expect(settings.tier == "CREDIT")
        #expect(settings.discountPercent == nil)
        #expect(settings.creditAmount == 12.5)   // parsed from the "12.50" string
    }

    @Test func rewardSettingsDecodesRecognitionNulls() async throws {
        reset(response: """
        {
          "ok": true,
          "settings": {
            "referralRewardEnabled": false,
            "referralRewardTier": "RECOGNITION",
            "referralDiscountPercent": null,
            "referralCreditAmount": null
          }
        }
        """)

        let settings = try await makeService().rewardSettings()
        #expect(settings.enabled == false)
        #expect(settings.tier == "RECOGNITION")
        #expect(settings.discountPercent == nil)
        #expect(settings.creditAmount == nil)
    }

    @Test func updateSendsCreditAsNumberNotString() async throws {
        reset(response: """
        {"ok":true,"settings":{"referralRewardEnabled":true,"referralRewardTier":"CREDIT","referralDiscountPercent":null,"referralCreditAmount":"15"}}
        """)

        let patch = ProReferralRewardSettingsPatch(enabled: true, tier: "CREDIT", creditAmount: 15)
        let updated = try await makeService().updateRewardSettings(patch)

        #expect(ProReferralRewardURLProtocol.capturedPath == "/api/v1/pro/settings/referral-rewards")
        #expect(ProReferralRewardURLProtocol.capturedMethod == "PATCH")

        let body = try bodyObject()
        #expect(body["referralRewardEnabled"] as? Bool == true)
        #expect(body["referralRewardTier"] as? String == "CREDIT")
        // The route validates `typeof v === 'number'` — it MUST be a JSON number.
        #expect(body["referralCreditAmount"] is NSNumber)
        #expect(body["referralCreditAmount"] is String == false)
        #expect((body["referralCreditAmount"] as? NSNumber)?.doubleValue == 15)
        // No discount for a CREDIT patch.
        #expect(body["referralDiscountPercent"] == nil)

        #expect(updated.tier == "CREDIT")
        #expect(updated.creditAmount == 15)
    }

    @Test func updateSendsDiscountAsIntegerOnly() async throws {
        reset(response: """
        {"ok":true,"settings":{"referralRewardEnabled":true,"referralRewardTier":"DISCOUNT","referralDiscountPercent":25,"referralCreditAmount":null}}
        """)

        let patch = ProReferralRewardSettingsPatch(enabled: true, tier: "DISCOUNT", discountPercent: 25)
        _ = try await makeService().updateRewardSettings(patch)

        let body = try bodyObject()
        #expect(body["referralRewardTier"] as? String == "DISCOUNT")
        #expect((body["referralDiscountPercent"] as? NSNumber)?.intValue == 25)
        // No credit for a DISCOUNT patch — leaves any stored credit untouched.
        #expect(body["referralCreditAmount"] == nil)
    }

    @Test func updateOmitsUnsetOptionalFields() async throws {
        reset(response: """
        {"ok":true,"settings":{"referralRewardEnabled":false,"referralRewardTier":"RECOGNITION","referralDiscountPercent":null,"referralCreditAmount":null}}
        """)

        // RECOGNITION / disabled: only the master switch + tier go out.
        let patch = ProReferralRewardSettingsPatch(enabled: false, tier: "RECOGNITION")
        _ = try await makeService().updateRewardSettings(patch)

        let body = try bodyObject()
        #expect(body["referralRewardEnabled"] as? Bool == false)
        #expect(body["referralRewardTier"] as? String == "RECOGNITION")
        #expect(body["referralDiscountPercent"] == nil)
        #expect(body["referralCreditAmount"] == nil)
        #expect(body.count == 2)   // nil optionals dropped entirely
    }
}
