import Foundation
import Testing
@testable import TovisKit

// Proves ProCameraService hits the right camera routes, encodes the vision
// request bodies, unwraps the response envelopes, and — the C2 tie-in —
// surfaces the server's machine-readable 403 CAMERA_QUOTA_EXCEEDED / 429 daily
// cap as an APIError that ProCameraAIError.from() classifies for the upgrade UX.
//
// Mocks at the URLProtocol layer (there's no APIClient protocol) — the same
// pattern as AddressesServiceTests.

/// Records the outgoing request and serves a canned envelope.
final class ProCameraURLProtocol: URLProtocol {
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
        Self.capturedBody = request.httpBody ?? request.proCameraBodyStreamData()

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
    func proCameraBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ProCameraServiceTests {
    private func makeService() async -> ProCameraService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProCameraURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.procamera.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProCameraService(api: api)
    }

    private func reset() {
        ProCameraURLProtocol.capturedPath = nil
        ProCameraURLProtocol.capturedMethod = nil
        ProCameraURLProtocol.capturedBody = nil
        ProCameraURLProtocol.status = 200
        ProCameraURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    private func decodeBody(_ data: Data?) throws -> [String: Any] {
        let body = try #require(data)
        let json = try JSONSerialization.jsonObject(with: body)
        return try #require(json as? [String: Any])
    }

    private func sampleLookBriefRequest() -> ProLookBriefRequest {
        ProLookBriefRequest(
            image: ProCameraVisionImage(base64: "aGVsbG8=", mediaType: "image/jpeg"),
            serviceName: "Balayage",
            measuredSummary: "fill 0.4"
        )
    }

    private func sampleSetCritiqueRequest() -> ProSetCritiqueRequest {
        ProSetCritiqueRequest(
            photos: [
                .init(id: "media-1", phase: "BEFORE",
                      image: ProCameraVisionImage(base64: "YmVmb3Jl")),
                .init(id: "media-2", phase: "AFTER",
                      image: ProCameraVisionImage(base64: "YWZ0ZXI=")),
            ],
            serviceName: "Balayage"
        )
    }

    // MARK: - shot-packs (GET)

    @Test func shotPacksGetsRouteAndDecodesHottestFirst() async throws {
        reset()
        ProCameraURLProtocol.responseBody = Data("""
        {"ok":true,"version":1,"packs":[
          {"id":"hair-reveal-v1","name":"The Reveal","tagline":"Back canvas first, then the turn.","serviceKeywords":["hair","balayage"],"trendScore":100,"steps":[
            {"title":"Back canvas","hint":"Square to their back","icon":"arrow.uturn.down","face":"absent","fillBandMin":0.25,"fillBandMax":0.9,"isDetail":false,"allowsClosedEyes":false,"pose":[{"kind":"shouldersLevel","params":{"maxDegrees":6},"tip":"Square their shoulders"}]}
          ]},
          {"id":"nails-claw-sparkle-v1","name":"Claw & Sparkle","tagline":"Hands framing the face.","serviceKeywords":["nail","gel"],"trendScore":85,"steps":[
            {"title":"Macro shine","hint":"One nail, low angle","icon":"magnifyingglass","face":"either","fillBandMin":null,"fillBandMax":null,"isDetail":true,"allowsClosedEyes":false,"pose":[]}
          ]}
        ]}
        """.utf8)

        let packs = try await makeService().shotPacks()

        #expect(ProCameraURLProtocol.capturedPath == "/api/v1/pro/camera/shot-packs")
        #expect(ProCameraURLProtocol.capturedMethod == "GET")
        // A GET carries no request body.
        #expect(ProCameraURLProtocol.capturedBody == nil)

        #expect(packs.version == 1)
        #expect(packs.packs.map(\.id) == ["hair-reveal-v1", "nails-claw-sparkle-v1"])
        #expect(packs.packs.first?.steps.first?.pose.first?.kind == "shouldersLevel")
    }

    // MARK: - usage (GET, unwraps the envelope)

    @Test func usageUnwrapsUsageEnvelope() async throws {
        reset()
        ProCameraURLProtocol.responseBody = Data("""
        {"usage":{"used":4,"baseQuota":30,"bonus":10,"quota":40,"remaining":36,"enforced":true}}
        """.utf8)

        let usage = try await makeService().usage()

        #expect(ProCameraURLProtocol.capturedPath == "/api/v1/pro/camera/usage")
        #expect(ProCameraURLProtocol.capturedMethod == "GET")
        #expect(usage.used == 4)
        #expect(usage.baseQuota == 30)
        #expect(usage.bonus == 10)
        #expect(usage.quota == 40)
        #expect(usage.remaining == 36)
        #expect(usage.enforced)
        #expect(usage.usedFraction == 0.1)
    }

    // MARK: - look-brief (POST, encodes body, unwraps the brief)

    @Test func lookBriefPostsBodyAndUnwrapsBrief() async throws {
        reset()
        ProCameraURLProtocol.responseBody = Data("""
        {"ok":true,"brief":{"summary":"Golden-hour glam","poseRules":[
          {"kind":"handNearFace","params":{"maxFaceHeights":1.2},"tip":"Hand up to the jaw"},
          {"kind":"someFutureRuleKind","params":{"mystery":1},"tip":"Future vocabulary decodes fine"}
        ],"directionLines":["Soft smile","Chin down a touch"]}}
        """.utf8)

        let brief = try await makeService().lookBrief(sampleLookBriefRequest())

        #expect(ProCameraURLProtocol.capturedPath == "/api/v1/pro/camera/look-brief")
        #expect(ProCameraURLProtocol.capturedMethod == "POST")

        let sent = try decodeBody(ProCameraURLProtocol.capturedBody)
        #expect(sent["serviceName"] as? String == "Balayage")
        #expect(sent["measuredSummary"] as? String == "fill 0.4")
        let image = try #require(sent["image"] as? [String: Any])
        #expect(image["base64"] as? String == "aGVsbG8=")
        #expect(image["mediaType"] as? String == "image/jpeg")

        #expect(brief.summary == "Golden-hour glam")
        #expect(brief.directionLines == ["Soft smile", "Chin down a touch"])
        // Unknown pose-rule kinds survive decode (dropped later at guide build).
        #expect(brief.poseRules.map(\.kind) == ["handNearFace", "someFutureRuleKind"])
    }

    // MARK: - set-critique (POST, encodes the photo set, unwraps the critique)

    @Test func setCritiquePostsPhotosAndUnwrapsCritique() async throws {
        reset()
        ProCameraURLProtocol.responseBody = Data("""
        {"ok":true,"critique":{"overall":"Publish the glance; retake the macro.","strengths":["Even warm light"],"photos":[
          {"id":"media-1","verdict":"portfolio","note":"Hero shot","retakeTip":null},
          {"id":"media-2","verdict":"retake","note":"Soft on the ends","retakeTip":"Step closer and tap to focus"}
        ]}}
        """.utf8)

        let critique = try await makeService().setCritique(sampleSetCritiqueRequest())

        #expect(ProCameraURLProtocol.capturedPath == "/api/v1/pro/camera/set-critique")
        #expect(ProCameraURLProtocol.capturedMethod == "POST")

        let sent = try decodeBody(ProCameraURLProtocol.capturedBody)
        #expect(sent["serviceName"] as? String == "Balayage")
        let photos = try #require(sent["photos"] as? [[String: Any]])
        #expect(photos.count == 2)
        #expect(photos.first?["id"] as? String == "media-1")
        #expect(photos.first?["phase"] as? String == "BEFORE")

        #expect(critique.overall == "Publish the glance; retake the macro.")
        #expect(critique.photos.map(\.id) == ["media-1", "media-2"])
        #expect(critique.photos.last?.retakeTip == "Step closer and tap to focus")
    }

    // MARK: - quota / rate-limit surfacing (the C2 contract)

    @Test func lookBrief403QuotaSurfacesAsUpgradeableQuotaError() async throws {
        reset()
        ProCameraURLProtocol.status = 403
        ProCameraURLProtocol.responseBody = Data("""
        {"ok":false,"error":"You've used all 30 AI photographer images this month.","code":"CAMERA_QUOTA_EXCEEDED"}
        """.utf8)

        do {
            _ = try await makeService().lookBrief(sampleLookBriefRequest())
            Issue.record("expected lookBrief to throw on a 403 quota response")
        } catch {
            // The service surfaces the server's machine-readable 403 verbatim…
            let apiError = try #require(error as? APIError)
            #expect(apiError == .server(
                status: 403,
                message: "You've used all 30 AI photographer images this month.",
                code: "CAMERA_QUOTA_EXCEEDED"))
            // …which the C2 classifier turns into an upgrade-offering quota error.
            let classified = ProCameraAIError.from(error)
            #expect(classified == .quotaExceeded(
                message: "You've used all 30 AI photographer images this month."))
            #expect(classified.offersUpgrade)
        }
    }

    @Test func setCritique429SurfacesAsDailyLimit() async throws {
        reset()
        ProCameraURLProtocol.status = 429
        ProCameraURLProtocol.responseBody = Data("""
        {"ok":false,"error":"Too many requests"}
        """.utf8)

        do {
            _ = try await makeService().setCritique(sampleSetCritiqueRequest())
            Issue.record("expected setCritique to throw on a 429 response")
        } catch {
            let apiError = try #require(error as? APIError)
            #expect(apiError == .server(status: 429, message: "Too many requests", code: nil))
            let classified = ProCameraAIError.from(error)
            #expect(classified == .dailyLimitReached)
            #expect(!classified.offersUpgrade)
        }
    }
}
