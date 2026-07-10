import Foundation
import Testing
@testable import TovisKit

// Proves the pro "Last Minute" editor write methods hit the right routes with the
// right verbs + bodies (all existing web routes — an iOS-only editor port):
//   • updateLastMinuteSettings    → PATCH  /pro/last-minute/settings  {whole form}
//   • updateLastMinuteServiceRule → PATCH  /pro/last-minute/rules     {serviceId,enabled,minCollectedSubtotal}
//   • addLastMinuteBlock          → POST   /pro/last-minute/blocks    {startAt,endAt,reason?}
//   • deleteLastMinuteBlock       → DELETE /pro/last-minute/blocks?id=
// The money floor is always emitted (explicit JSON null clears it server-side).

/// Records the outgoing request and serves a canned envelope.
final class ProLastMinuteWritesURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedQuery: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedQuery = request.url?.query
        Self.capturedMethod = request.httpMethod
        Self.capturedBody = request.httpBody ?? request.lastMinuteBodyStreamData()

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
    func lastMinuteBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ProLastMinuteWritesTests {
    private func makeService() async -> ProScheduleService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProLastMinuteWritesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.lastminute.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProScheduleService(api: api)
    }

    private func reset() {
        ProLastMinuteWritesURLProtocol.capturedPath = nil
        ProLastMinuteWritesURLProtocol.capturedQuery = nil
        ProLastMinuteWritesURLProtocol.capturedMethod = nil
        ProLastMinuteWritesURLProtocol.capturedBody = nil
        ProLastMinuteWritesURLProtocol.status = 200
        ProLastMinuteWritesURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    private func bodyJSON() throws -> [String: Any] {
        let body = try #require(ProLastMinuteWritesURLProtocol.capturedBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func updateSettingsPatchesWholeFormWithSetFloor() async throws {
        reset()
        let request = ProLastMinuteSettingsPatchRequest(
            enabled: true,
            defaultVisibilityMode: "PUBLIC_IMMEDIATE",
            minCollectedSubtotal: "80",
            tier2NightBeforeMinutes: 1140,
            tier3DayOfMinutes: 540,
            priorityOfferEnabled: true,
            priorityOfferMinutes: 30,
            disableMon: false, disableTue: false, disableWed: true,
            disableThu: false, disableFri: false, disableSat: true, disableSun: false
        )
        try await makeService().updateLastMinuteSettings(request)

        #expect(ProLastMinuteWritesURLProtocol.capturedPath == "/api/v1/pro/last-minute/settings")
        #expect(ProLastMinuteWritesURLProtocol.capturedMethod == "PATCH")

        let json = try bodyJSON()
        #expect(json["enabled"] as? Bool == true)
        #expect(json["defaultVisibilityMode"] as? String == "PUBLIC_IMMEDIATE")
        #expect(json["minCollectedSubtotal"] as? String == "80")
        #expect(json["tier2NightBeforeMinutes"] as? Int == 1140)
        #expect(json["tier3DayOfMinutes"] as? Int == 540)
        #expect(json["priorityOfferEnabled"] as? Bool == true)
        #expect(json["priorityOfferMinutes"] as? Int == 30)
        #expect(json["disableWed"] as? Bool == true)
        #expect(json["disableSat"] as? Bool == true)
        #expect(json["disableMon"] as? Bool == false)
    }

    @Test func updateSettingsEmitsExplicitNullFloor() async throws {
        reset()
        let request = ProLastMinuteSettingsPatchRequest(
            enabled: false,
            defaultVisibilityMode: "TARGETED_ONLY",
            minCollectedSubtotal: nil,
            tier2NightBeforeMinutes: 0,
            tier3DayOfMinutes: 0,
            priorityOfferEnabled: false,
            priorityOfferMinutes: 5,
            disableMon: false, disableTue: false, disableWed: false,
            disableThu: false, disableFri: false, disableSat: false, disableSun: false
        )
        try await makeService().updateLastMinuteSettings(request)

        let json = try bodyJSON()
        // The key must be PRESENT as JSON null (a dropped key wouldn't clear the floor).
        #expect(json.keys.contains("minCollectedSubtotal"))
        #expect(json["minCollectedSubtotal"] is NSNull)
    }

    @Test func updateServiceRulePatchesFields() async throws {
        reset()
        try await makeService().updateLastMinuteServiceRule(
            serviceId: "svc_1", enabled: false, minCollectedSubtotal: "120.50"
        )

        #expect(ProLastMinuteWritesURLProtocol.capturedPath == "/api/v1/pro/last-minute/rules")
        #expect(ProLastMinuteWritesURLProtocol.capturedMethod == "PATCH")

        let json = try bodyJSON()
        #expect(json["serviceId"] as? String == "svc_1")
        #expect(json["enabled"] as? Bool == false)
        #expect(json["minCollectedSubtotal"] as? String == "120.50")
    }

    @Test func updateServiceRuleEmitsExplicitNullFloor() async throws {
        reset()
        try await makeService().updateLastMinuteServiceRule(
            serviceId: "svc_2", enabled: true, minCollectedSubtotal: nil
        )
        let json = try bodyJSON()
        #expect(json["serviceId"] as? String == "svc_2")
        #expect(json.keys.contains("minCollectedSubtotal"))
        #expect(json["minCollectedSubtotal"] is NSNull)
    }

    @Test func addBlockPostsRangeWithReason() async throws {
        reset()
        try await makeService().addLastMinuteBlock(
            startAt: "2026-07-11T18:00:00Z", endAt: "2026-07-11T20:00:00Z", reason: "Prep time"
        )

        #expect(ProLastMinuteWritesURLProtocol.capturedPath == "/api/v1/pro/last-minute/blocks")
        #expect(ProLastMinuteWritesURLProtocol.capturedMethod == "POST")

        let json = try bodyJSON()
        #expect(json["startAt"] as? String == "2026-07-11T18:00:00Z")
        #expect(json["endAt"] as? String == "2026-07-11T20:00:00Z")
        #expect(json["reason"] as? String == "Prep time")
    }

    @Test func addBlockOmitsNilReason() async throws {
        reset()
        try await makeService().addLastMinuteBlock(
            startAt: "2026-07-11T18:00:00Z", endAt: "2026-07-11T20:00:00Z", reason: nil
        )
        let json = try bodyJSON()
        #expect(json["reason"] == nil)
    }

    @Test func deleteBlockSendsIdQuery() async throws {
        reset()
        try await makeService().deleteLastMinuteBlock(id: "blk_9")

        #expect(ProLastMinuteWritesURLProtocol.capturedPath == "/api/v1/pro/last-minute/blocks")
        #expect(ProLastMinuteWritesURLProtocol.capturedMethod == "DELETE")
        #expect(ProLastMinuteWritesURLProtocol.capturedQuery == "id=blk_9")
    }
}
