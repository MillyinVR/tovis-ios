import Foundation
import Testing
@testable import TovisKit

// Proves the per-tab write forms on the pro client chart hit the right routes with
// the right verbs + bodies:
//   • addAllergy          → POST   /pro/clients/{id}/allergies  {label,description,severity}
//   • updateAlertBanner   → PATCH  /pro/clients/{id}/alert      {alertBanner}
//   • setDoNotRebook      → PUT    /pro/clients/{id}/do-not-rebook {reason}
//   • clearDoNotRebook    → DELETE /pro/clients/{id}/do-not-rebook
//   • updateProfileContext→ PATCH  /pro/clients/{id}/profile-context {occupation,proCapturedSocialHandle}
//   • addFormula          → POST   /pro/clients/{id}/formula        {brand,developer,ratio,processingTimeMinutes,resultNotes}
//   • addConsent          → POST   /pro/clients/{id}/consent        {kind,serviceScope,proofMethod,signedAt,notes,patchTestResult,validUntil}
//   • updatePhotoRelease  → PATCH  /pro/clients/{id}/photo-release  {status}
// Every write is an authenticated native request; the routes encrypt free text
// server-side, so the client only sends plaintext.

/// Records the outgoing request and serves a canned envelope.
final class ProClientChartWritesURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedAuthHeader: String?
    nonisolated(unsafe) static var capturedNativeHeader: String?
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
        Self.capturedBody = request.httpBody ?? request.chartWritesBodyStreamData()

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
    func chartWritesBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ProClientChartWritesTests {
    private func makeService() async -> ProClientsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProClientChartWritesURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.chartwrites.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProClientsService(api: api)
    }

    private func reset() {
        ProClientChartWritesURLProtocol.capturedPath = nil
        ProClientChartWritesURLProtocol.capturedMethod = nil
        ProClientChartWritesURLProtocol.capturedAuthHeader = nil
        ProClientChartWritesURLProtocol.capturedNativeHeader = nil
        ProClientChartWritesURLProtocol.capturedBody = nil
        ProClientChartWritesURLProtocol.status = 200
        ProClientChartWritesURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    private func bodyJSON() throws -> [String: Any] {
        let body = try #require(ProClientChartWritesURLProtocol.capturedBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func addAllergyPostsPlaintextFields() async throws {
        reset()
        try await makeService().addAllergy(
            clientId: "cl_1", label: "PPD", description: "scalp redness", severity: "HIGH"
        )

        #expect(ProClientChartWritesURLProtocol.capturedPath == "/api/v1/pro/clients/cl_1/allergies")
        #expect(ProClientChartWritesURLProtocol.capturedMethod == "POST")
        #expect(ProClientChartWritesURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(ProClientChartWritesURLProtocol.capturedNativeHeader == "ios")

        let json = try bodyJSON()
        #expect(json["label"] as? String == "PPD")
        #expect(json["description"] as? String == "scalp redness")
        #expect(json["severity"] as? String == "HIGH")
    }

    @Test func addAllergyOmitsNilDescription() async throws {
        reset()
        try await makeService().addAllergy(
            clientId: "cl_1", label: "Latex", description: nil, severity: "MODERATE"
        )
        let json = try bodyJSON()
        #expect(json["label"] as? String == "Latex")
        #expect(json["description"] == nil)
    }

    @Test func updateAlertBannerPatchesBanner() async throws {
        reset()
        try await makeService().updateAlertBanner(clientId: "cl_2", alertBanner: "Sensitive scalp")

        #expect(ProClientChartWritesURLProtocol.capturedPath == "/api/v1/pro/clients/cl_2/alert")
        #expect(ProClientChartWritesURLProtocol.capturedMethod == "PATCH")
        let json = try bodyJSON()
        #expect(json["alertBanner"] as? String == "Sensitive scalp")
    }

    @Test func updateAlertBannerClearsWithEmptyString() async throws {
        reset()
        try await makeService().updateAlertBanner(clientId: "cl_2", alertBanner: "")
        let json = try bodyJSON()
        #expect(json["alertBanner"] as? String == "")
    }

    @Test func setDoNotRebookPutsReason() async throws {
        reset()
        try await makeService().setDoNotRebook(clientId: "cl_3", reason: "No-showed twice")

        #expect(ProClientChartWritesURLProtocol.capturedPath == "/api/v1/pro/clients/cl_3/do-not-rebook")
        #expect(ProClientChartWritesURLProtocol.capturedMethod == "PUT")
        let json = try bodyJSON()
        #expect(json["reason"] as? String == "No-showed twice")
    }

    @Test func clearDoNotRebookDeletes() async throws {
        reset()
        try await makeService().clearDoNotRebook(clientId: "cl_3")

        #expect(ProClientChartWritesURLProtocol.capturedPath == "/api/v1/pro/clients/cl_3/do-not-rebook")
        #expect(ProClientChartWritesURLProtocol.capturedMethod == "DELETE")
    }

    @Test func updateProfileContextPatchesBothFields() async throws {
        reset()
        try await makeService().updateProfileContext(
            clientId: "cl_4", occupation: "Nurse (rotating shifts)", socialHandle: "theirhandle"
        )

        #expect(ProClientChartWritesURLProtocol.capturedPath == "/api/v1/pro/clients/cl_4/profile-context")
        #expect(ProClientChartWritesURLProtocol.capturedMethod == "PATCH")
        let json = try bodyJSON()
        #expect(json["occupation"] as? String == "Nurse (rotating shifts)")
        #expect(json["proCapturedSocialHandle"] as? String == "theirhandle")
    }

    // MARK: - Technical record writes (formula · consent · photo-release)

    @Test func addFormulaPostsDetails() async throws {
        reset()
        try await makeService().addFormula(
            clientId: "cl_5", brand: "Wella", developer: "20 vol", ratio: "1:1",
            processingTimeMinutes: 35, resultNotes: "Lifted to level 8"
        )

        #expect(ProClientChartWritesURLProtocol.capturedPath == "/api/v1/pro/clients/cl_5/formula")
        #expect(ProClientChartWritesURLProtocol.capturedMethod == "POST")
        #expect(ProClientChartWritesURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(ProClientChartWritesURLProtocol.capturedNativeHeader == "ios")

        let json = try bodyJSON()
        #expect(json["brand"] as? String == "Wella")
        #expect(json["developer"] as? String == "20 vol")
        #expect(json["ratio"] as? String == "1:1")
        #expect(json["processingTimeMinutes"] as? Int == 35)
        #expect(json["resultNotes"] as? String == "Lifted to level 8")
        // Nil optionals are omitted (no booking tie).
        #expect(json["bookingId"] == nil)
    }

    @Test func addConsentPostsPatchTest() async throws {
        reset()
        try await makeService().addConsent(
            clientId: "cl_6", kind: "PATCH_TEST", serviceScope: "color",
            proofMethod: "IN_PERSON", proofRef: nil, signedAt: "2026-06-01",
            notes: "ok", patchTestResult: "PASS", validUntil: "2026-12-01"
        )

        #expect(ProClientChartWritesURLProtocol.capturedPath == "/api/v1/pro/clients/cl_6/consent")
        #expect(ProClientChartWritesURLProtocol.capturedMethod == "POST")

        let json = try bodyJSON()
        #expect(json["kind"] as? String == "PATCH_TEST")
        #expect(json["serviceScope"] as? String == "color")
        #expect(json["proofMethod"] as? String == "IN_PERSON")
        #expect(json["signedAt"] as? String == "2026-06-01")
        #expect(json["notes"] as? String == "ok")
        #expect(json["patchTestResult"] as? String == "PASS")
        #expect(json["validUntil"] as? String == "2026-12-01")
        // proofRef is nil → omitted from the body.
        #expect(json["proofRef"] == nil)
    }

    @Test func updatePhotoReleasePatchesStatus() async throws {
        reset()
        try await makeService().updatePhotoRelease(clientId: "cl_7", status: "GRANTED")

        #expect(ProClientChartWritesURLProtocol.capturedPath == "/api/v1/pro/clients/cl_7/photo-release")
        #expect(ProClientChartWritesURLProtocol.capturedMethod == "PATCH")

        let json = try bodyJSON()
        #expect(json["status"] as? String == "GRANTED")
    }

    // MARK: - Public profile (view=public toggle)

    @Test func publicProfileGetsAndUnwrapsEnvelope() async throws {
        reset()
        ProClientChartWritesURLProtocol.responseBody = Data("""
        {"ok":true,"profile":{"handle":"ava","displayName":"@ava","avatarUrl":null,
        "bio":"Balayage lover","counts":{"followers":12,"following":3,"looks":1},
        "looks":[{"id":"lk_1","name":"Sunlit","imageUrl":"https://cdn/1.jpg","saveCount":8,"href":"/looks/lk_1"}],
        "viewer":{"isOwn":false,"following":false}}}
        """.utf8)

        let profile = try await makeService().publicProfile(clientId: "cl_8")

        #expect(ProClientChartWritesURLProtocol.capturedPath == "/api/v1/pro/clients/cl_8/public-profile")
        #expect(ProClientChartWritesURLProtocol.capturedMethod == "GET")
        #expect(profile?.handle == "ava")
        #expect(profile?.displayName == "@ava")
        #expect(profile?.counts.followers == 12)
        #expect(profile?.looks.first?.saveCount == 8)
        #expect(profile?.viewer.isOwn == false)
    }

    @Test func publicProfileReturnsNilWhenClientHasNoProfile() async throws {
        reset()
        // The route answers 200 with `profile: null` when the client hasn't opted
        // into a public profile — the service surfaces that as nil (empty state),
        // NOT a thrown error.
        ProClientChartWritesURLProtocol.responseBody = Data("{\"ok\":true,\"profile\":null}".utf8)

        let profile = try await makeService().publicProfile(clientId: "cl_9")

        #expect(ProClientChartWritesURLProtocol.capturedPath == "/api/v1/pro/clients/cl_9/public-profile")
        #expect(profile == nil)
    }
}
