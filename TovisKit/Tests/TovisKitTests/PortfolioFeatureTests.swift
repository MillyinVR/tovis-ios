import Foundation
import Testing
@testable import TovisKit

// Proves the pro "feature media in portfolio" toggle hits the shared media route
// with the right verb and body — matching the web `MediaPortfolioToggle`:
//   • setMediaFeaturedInPortfolio(_, featured: true)  → POST   /pro/media/{id}/portfolio
//   • setMediaFeaturedInPortfolio(_, featured: false) → DELETE /pro/media/{id}/portfolio
// By default the POST carries no body — the route auto-pairs before/after server-side.
// The wrap-up "publish this transformation" path passes an explicit `beforeAssetId`
// to pin the exact pair the pro is viewing; that (and only that) rides in a JSON body.

/// Records the outgoing request and serves the route's canned `{ ok, media }` envelope.
final class PortfolioFeatureURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedAuthHeader: String?
    nonisolated(unsafe) static var capturedNativeHeader: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data(
        "{\"ok\":true,\"media\":{\"id\":\"media_1\",\"isFeaturedInPortfolio\":true}}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedAuthHeader = request.value(forHTTPHeaderField: "Authorization")
        Self.capturedNativeHeader = request.value(forHTTPHeaderField: "x-tovis-native")
        Self.capturedBody = request.httpBody ?? request.portfolioBodyStreamData()

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
    func portfolioBodyStreamData() -> Data? {
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

@Suite(.serialized) struct PortfolioFeatureTests {
    private func makeService() async -> ProProfileService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PortfolioFeatureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.portfolio.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProProfileService(api: api)
    }

    private func reset() {
        PortfolioFeatureURLProtocol.capturedPath = nil
        PortfolioFeatureURLProtocol.capturedMethod = nil
        PortfolioFeatureURLProtocol.capturedAuthHeader = nil
        PortfolioFeatureURLProtocol.capturedNativeHeader = nil
        PortfolioFeatureURLProtocol.capturedBody = nil
        PortfolioFeatureURLProtocol.status = 200
    }

    @Test func featurePostsToPortfolioRouteWithNoBody() async throws {
        reset()
        try await makeService().setMediaFeaturedInPortfolio(mediaId: "media_1", featured: true)

        #expect(PortfolioFeatureURLProtocol.capturedPath == "/api/v1/pro/media/media_1/portfolio")
        #expect(PortfolioFeatureURLProtocol.capturedMethod == "POST")
        #expect(PortfolioFeatureURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect(PortfolioFeatureURLProtocol.capturedNativeHeader == "ios")
        // The web toggle sends no body; the route auto-pairs before/after itself.
        #expect((PortfolioFeatureURLProtocol.capturedBody?.isEmpty ?? true))
    }

    @Test func featureWithExplicitBeforePinsPairingInBody() async throws {
        reset()
        PortfolioFeatureURLProtocol.responseBody = Data(
            "{\"ok\":true,\"media\":{\"id\":\"media_5\",\"isFeaturedInPortfolio\":true}}".utf8)
        try await makeService().setMediaFeaturedInPortfolio(
            mediaId: "media_5", beforeAssetId: "before_9", featured: true)

        #expect(PortfolioFeatureURLProtocol.capturedPath == "/api/v1/pro/media/media_5/portfolio")
        #expect(PortfolioFeatureURLProtocol.capturedMethod == "POST")
        // An explicit before pins the comparison partner instead of the auto-pair.
        let body = try #require(PortfolioFeatureURLProtocol.capturedBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["beforeAssetId"] as? String == "before_9")
    }

    @Test func unfeatureDeletesPortfolioRoute() async throws {
        reset()
        try await makeService().setMediaFeaturedInPortfolio(mediaId: "media_2", featured: false)

        #expect(PortfolioFeatureURLProtocol.capturedPath == "/api/v1/pro/media/media_2/portfolio")
        #expect(PortfolioFeatureURLProtocol.capturedMethod == "DELETE")
        #expect(PortfolioFeatureURLProtocol.capturedAuthHeader == "Bearer session.token.value")
        #expect((PortfolioFeatureURLProtocol.capturedBody?.isEmpty ?? true))
    }

    @Test func surfacesServerErrorOnConsentGate() async throws {
        reset()
        // The route 403s an unpromoted private session photo. Review media is
        // consented, but any failure must throw (the view surfaces it), not swallow.
        PortfolioFeatureURLProtocol.status = 403
        PortfolioFeatureURLProtocol.responseBody = Data(
            "{\"ok\":false,\"error\":\"This session photo can only be shared publicly after the client adds it to a review.\"}".utf8)

        var threw = false
        do {
            try await makeService().setMediaFeaturedInPortfolio(mediaId: "media_4", featured: true)
        } catch {
            threw = true
        }
        #expect(threw)
        // The request was still attempted at the right path/verb before failing.
        #expect(PortfolioFeatureURLProtocol.capturedPath == "/api/v1/pro/media/media_4/portfolio")
        #expect(PortfolioFeatureURLProtocol.capturedMethod == "POST")
    }
}
