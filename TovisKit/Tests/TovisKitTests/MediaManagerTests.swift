import Foundation
import Testing
@testable import TovisKit

// Proves the pro media-manager service methods hit the right routes with the
// right verbs/bodies — the native counterpart of the web `/pro/media` grid +
// `OwnerMediaMenu` editor:
//   • listManagedMedia()  → GET    /pro/media           (decodes items + options)
//   • updateMedia(...)     → PATCH  /pro/media/{id}       (full-set body; caption
//                                                          omitted when nil → clear)
//   • beforeOptions(_)     → GET    /pro/media/{id}/before-options (pairing picker)
//   • deleteMedia(_)       → DELETE /pro/media/{id}
// `visibility` is never sent (the server derives it from the flags). `beforeAssetId`
// follows a 3-state pairing contract: omitted when untouched (preserves auto-pairing),
// a value when paired, an explicit null when unpaired.

/// Records the outgoing request and serves a canned envelope.
final class MediaManagerURLProtocol: URLProtocol {
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
        Self.capturedBody = request.httpBody ?? request.mediaManagerBodyStreamData()

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
    func mediaManagerBodyStreamData() -> Data? {
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

@Suite(.serialized) struct MediaManagerTests {
    private func makeService() async -> ProMediaService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaManagerURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.mediamanager.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProMediaService(api: api, supabaseURL: nil, supabaseKey: nil)
    }

    private func reset() {
        MediaManagerURLProtocol.capturedPath = nil
        MediaManagerURLProtocol.capturedMethod = nil
        MediaManagerURLProtocol.capturedAuthHeader = nil
        MediaManagerURLProtocol.capturedNativeHeader = nil
        MediaManagerURLProtocol.capturedBody = nil
        MediaManagerURLProtocol.status = 200
        MediaManagerURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    private func bodyJSON() throws -> [String: Any] {
        let data = try #require(MediaManagerURLProtocol.capturedBody)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(json)
    }

    @Test func listGetsMediaRouteAndDecodesItemsAndOptions() async throws {
        reset()
        MediaManagerURLProtocol.responseBody = Data("""
        {
          "ok": true,
          "items": [
            {
              "id": "media_1",
              "mediaType": "IMAGE",
              "visibility": "PUBLIC",
              "caption": "Fresh set",
              "createdAt": "2026-04-21T00:00:00.000Z",
              "reviewId": null,
              "isEligibleForLooks": false,
              "isFeaturedInPortfolio": true,
              "isCoverMedia": true,
              "beforeAssetId": "media_before",
              "services": [{ "serviceId": "s1", "name": "Gel X" }],
              "url": "https://cdn.example/x.jpg",
              "thumbUrl": null,
              "renderUrl": "https://signed.example/x.jpg",
              "renderThumbUrl": "https://signed.example/x_thumb.jpg"
            }
          ],
          "serviceOptions": [
            { "serviceId": "s1", "name": "Gel X" },
            { "serviceId": "s2", "name": "Nail Art" }
          ]
        }
        """.utf8)

        let response = try await makeService().listManagedMedia()

        #expect(MediaManagerURLProtocol.capturedPath == "/api/v1/pro/media")
        #expect(MediaManagerURLProtocol.capturedMethod == "GET")
        #expect(MediaManagerURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(MediaManagerURLProtocol.capturedNativeHeader == "ios")

        #expect(response.items.count == 1)
        let item = try #require(response.items.first)
        #expect(item.id == "media_1")
        #expect(item.caption == "Fresh set")
        #expect(item.isFeaturedInPortfolio == true)
        #expect(item.isEligibleForLooks == false)
        #expect(item.isCoverMedia == true)
        #expect(item.beforeAssetId == "media_before")
        #expect(item.serviceIds == ["s1"])
        #expect(item.displayThumbUrl == "https://signed.example/x_thumb.jpg")
        #expect(response.serviceOptions.map(\.serviceId) == ["s1", "s2"])
    }

    @Test func updatePatchesMediaRouteWithFullBody() async throws {
        reset()
        try await makeService().updateMedia(
            mediaId: "media_1",
            caption: "Fresh set",
            isEligibleForLooks: true,
            isFeaturedInPortfolio: false,
            serviceIds: ["s1", "s2"]
        )

        #expect(MediaManagerURLProtocol.capturedPath == "/api/v1/pro/media/media_1")
        #expect(MediaManagerURLProtocol.capturedMethod == "PATCH")
        #expect(MediaManagerURLProtocol.capturedAuthHeader == "Bearer session.token.value")

        let body = try bodyJSON()
        #expect(body["caption"] as? String == "Fresh set")
        #expect(body["isEligibleForLooks"] as? Bool == true)
        #expect(body["isFeaturedInPortfolio"] as? Bool == false)
        #expect(body["serviceIds"] as? [String] == ["s1", "s2"])
        // Visibility is derived server-side; the client never sends it. Pairing is
        // left untouched (a core edit omits beforeAssetId).
        #expect(body["visibility"] == nil)
        #expect(body["beforeAssetId"] == nil)
    }

    @Test func updateOmitsCaptionKeyWhenNilToClearIt() async throws {
        reset()
        try await makeService().updateMedia(
            mediaId: "media_1",
            caption: nil,
            isEligibleForLooks: false,
            isFeaturedInPortfolio: true,
            serviceIds: ["s1"]
        )

        let body = try bodyJSON()
        // A nil caption is omitted; the server coerces an absent caption to null.
        #expect(body["caption"] == nil)
        #expect(body["isFeaturedInPortfolio"] as? Bool == true)
        #expect(body["serviceIds"] as? [String] == ["s1"])
    }

    @Test func beforeOptionsGetsRouteAndDecodesCandidates() async throws {
        reset()
        MediaManagerURLProtocol.responseBody = Data("""
        {
          "ok": true,
          "options": [
            { "id": "before_1", "thumbUrl": "https://signed.example/b1.jpg", "phase": "BEFORE" },
            { "id": "other_2", "thumbUrl": "https://signed.example/o2.jpg", "phase": "OTHER" }
          ]
        }
        """.utf8)

        let options = try await makeService().beforeOptions(mediaId: "media_1")

        #expect(MediaManagerURLProtocol.capturedPath == "/api/v1/pro/media/media_1/before-options")
        #expect(MediaManagerURLProtocol.capturedMethod == "GET")
        #expect(MediaManagerURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(options.map(\.id) == ["before_1", "other_2"])
        #expect(options.first?.phase == .before)
        #expect(options.first?.thumbUrl == "https://signed.example/b1.jpg")
    }

    @Test func updateSendsBeforeAssetIdWhenPairingSet() async throws {
        reset()
        try await makeService().updateMedia(
            mediaId: "media_1",
            caption: "Fresh set",
            isEligibleForLooks: false,
            isFeaturedInPortfolio: true,
            serviceIds: ["s1"],
            pairing: .set("before_1")
        )

        let body = try bodyJSON()
        // A touched picker with a chosen before sends the id (server pairs it).
        #expect(body["beforeAssetId"] as? String == "before_1")
        #expect(body["isFeaturedInPortfolio"] as? Bool == true)
    }

    @Test func updateSendsExplicitNullWhenPairingCleared() async throws {
        reset()
        try await makeService().updateMedia(
            mediaId: "media_1",
            caption: "Fresh set",
            isEligibleForLooks: false,
            isFeaturedInPortfolio: true,
            serviceIds: ["s1"],
            pairing: .set(nil)
        )

        let body = try bodyJSON()
        // A touched picker set to "None" sends an explicit JSON null (server unpairs);
        // the key must be PRESENT (null), not omitted.
        #expect(body.keys.contains("beforeAssetId"))
        #expect(body["beforeAssetId"] is NSNull)
    }

    @Test func deleteHitsMediaRoute() async throws {
        reset()
        try await makeService().deleteMedia(mediaId: "media_9")

        #expect(MediaManagerURLProtocol.capturedPath == "/api/v1/pro/media/media_9")
        #expect(MediaManagerURLProtocol.capturedMethod == "DELETE")
        #expect((MediaManagerURLProtocol.capturedBody?.isEmpty ?? true))
    }

    @Test func setCoverPostsCoverRoute() async throws {
        reset()
        try await makeService().setCover(mediaId: "media_3")

        #expect(MediaManagerURLProtocol.capturedPath == "/api/v1/pro/media/media_3/cover")
        #expect(MediaManagerURLProtocol.capturedMethod == "POST")
        #expect(MediaManagerURLProtocol.capturedAuthHeader == "Bearer session.token.value")
    }

    @Test func removeCoverDeletesCoverRoute() async throws {
        reset()
        try await makeService().removeCover(mediaId: "media_3")

        #expect(MediaManagerURLProtocol.capturedPath == "/api/v1/pro/media/media_3/cover")
        #expect(MediaManagerURLProtocol.capturedMethod == "DELETE")
    }

    @Test func setCoverSurfacesConsentGate() async throws {
        reset()
        // A private/unpromoted photo can't be a public cover — the server 403s and
        // the sheet surfaces it; a failure must throw, never be swallowed.
        MediaManagerURLProtocol.status = 403
        MediaManagerURLProtocol.responseBody = Data(
            "{\"ok\":false,\"error\":\"This session photo can only be shared publicly after the client adds it to a review.\"}".utf8)

        var threw = false
        do { try await makeService().setCover(mediaId: "media_7") } catch { threw = true }
        #expect(threw)
        #expect(MediaManagerURLProtocol.capturedPath == "/api/v1/pro/media/media_7/cover")
        #expect(MediaManagerURLProtocol.capturedMethod == "POST")
    }

    @Test func surfacesServerErrorOnConsentGate() async throws {
        reset()
        // The PATCH 403s when flipping an unpromoted private session photo public.
        // Any failure must throw (the sheet surfaces it), not be swallowed.
        MediaManagerURLProtocol.status = 403
        MediaManagerURLProtocol.responseBody = Data(
            "{\"ok\":false,\"error\":\"This session photo can only be shared publicly after the client adds it to a review.\"}".utf8)

        var threw = false
        do {
            try await makeService().updateMedia(
                mediaId: "media_5",
                caption: "x",
                isEligibleForLooks: false,
                isFeaturedInPortfolio: true,
                serviceIds: ["s1"]
            )
        } catch {
            threw = true
        }
        #expect(threw)
        #expect(MediaManagerURLProtocol.capturedPath == "/api/v1/pro/media/media_5")
        #expect(MediaManagerURLProtocol.capturedMethod == "PATCH")
    }
}
