import Foundation
import Testing
@testable import TovisKit

// Covers the three wire contracts behind parity step 10:
//   • LooksService.hide()            → POST /looks/{id}/hide      ("Not for me")
//   • LooksService.feed(query:)      → GET  /looks?q=…            (feed search)
//   • DiscoverService.searchServices → GET  /search/services      (services tab)
//   • DiscoverService.searchPros(serviceId:) → GET /search/pros?serviceId=…
//
// The assertions that matter here are the OMISSIONS, not the happy paths. A blank
// `q` must not reach the server (a present `q` routes the looks feed off the
// personalized path onto chronological search), and a nil `serviceId` must leave
// the pros query byte-identical for every existing caller. Both are the kind of
// thing that fails silently — the request still succeeds, it just quietly answers
// a different question.

/// Records the outgoing request and serves a canned envelope.
final class FeedDiscoveryURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedQuery: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedQuery = request.url?.query
        Self.capturedMethod = request.httpMethod

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

@Suite(.serialized) struct FeedDiscoveryServiceTests {
    private func makeAPI() async -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedDiscoveryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.feeddiscovery.tests")
        await tokenStore.save("session.token.value")
        return APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
    }

    private func reset() {
        FeedDiscoveryURLProtocol.capturedPath = nil
        FeedDiscoveryURLProtocol.capturedQuery = nil
        FeedDiscoveryURLProtocol.capturedMethod = nil
        FeedDiscoveryURLProtocol.status = 200
        FeedDiscoveryURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    /// The query string as name→value pairs, so assertions don't depend on order.
    private func queryItems() -> [String: String] {
        guard let query = FeedDiscoveryURLProtocol.capturedQuery else { return [:] }
        var out: [String: String] = [:]
        for pair in URLComponents(string: "?\(query)")?.queryItems ?? [] {
            out[pair.name] = pair.value
        }
        return out
    }

    private let emptyFeed = Data("{\"ok\":true,\"items\":[],\"nextCursor\":null}".utf8)

    // MARK: - "Not for me"

    @Test func hidePostsToTheLookHideRoute() async throws {
        reset()
        FeedDiscoveryURLProtocol.responseBody = Data("""
        {"ok":true,"lookPostId":"look_1","hidden":true}
        """.utf8)

        let res = try await LooksService(api: await makeAPI()).hide(lookId: "look_1")

        #expect(FeedDiscoveryURLProtocol.capturedPath == "/api/v1/looks/look_1/hide")
        #expect(FeedDiscoveryURLProtocol.capturedMethod == "POST")
        #expect(res.lookPostId == "look_1")
        #expect(res.hidden == true)
    }

    /// A duplicate hide is swallowed server-side (P2002) and still reports hidden.
    /// The client must not treat that as a no-op it needs to reconcile.
    @Test func hideIsIdempotentFromTheClientsPointOfView() async throws {
        reset()
        FeedDiscoveryURLProtocol.responseBody = Data("""
        {"ok":true,"lookPostId":"look_1","hidden":true}
        """.utf8)

        let res = try await LooksService(api: await makeAPI()).hide(lookId: "look_1")
        #expect(res.hidden == true)
    }

    @Test func hideSurfacesTheServerErrorForAnUnviewableLook() async throws {
        reset()
        FeedDiscoveryURLProtocol.status = 404
        FeedDiscoveryURLProtocol.responseBody = Data("""
        {"ok":false,"error":"Not found.","code":"LOOK_NOT_FOUND"}
        """.utf8)

        let service = LooksService(api: await makeAPI())
        await #expect(throws: APIError.server(
            status: 404, message: "Not found.", code: "LOOK_NOT_FOUND"
        )) {
            _ = try await service.hide(lookId: "look_gone")
        }
    }

    // MARK: - Feed search

    @Test func feedSendsTheTrimmedSearchQuery() async throws {
        reset()
        FeedDiscoveryURLProtocol.responseBody = emptyFeed

        _ = try await LooksService(api: await makeAPI()).feed(query: "  balayage  ")

        #expect(FeedDiscoveryURLProtocol.capturedPath == "/api/v1/looks")
        #expect(queryItems()["q"] == "balayage")
    }

    /// The load-bearing omission: a present `q` switches the server off the
    /// personalized feed onto chronological search, so a blank box must not send
    /// one. Web guards this with `if (query.trim())`.
    @Test func feedOmitsQEntirelyForABlankQuery() async throws {
        reset()
        FeedDiscoveryURLProtocol.responseBody = emptyFeed
        let service = LooksService(api: await makeAPI())

        for blank in ["", "   ", "\n\t "] {
            _ = try await service.feed(query: blank)
            #expect(queryItems()["q"] == nil, "q must be omitted for \(blank.debugDescription)")
        }

        // nil is the default for every existing caller.
        _ = try await service.feed()
        #expect(queryItems()["q"] == nil)
    }

    @Test func feedKeepsQueryAlongsideTheTabParams() async throws {
        reset()
        FeedDiscoveryURLProtocol.responseBody = emptyFeed

        _ = try await LooksService(api: await makeAPI()).feed(
            category: "hair", following: true, query: "curls", cursor: "cur_1"
        )

        let items = queryItems()
        #expect(items["q"] == "curls")
        #expect(items["category"] == "hair")
        #expect(items["following"] == "true")
        #expect(items["cursor"] == "cur_1")
    }

    // MARK: - Services search

    @Test func searchServicesHitsTheSiblingRouteAndDecodesTheCursor() async throws {
        reset()
        FeedDiscoveryURLProtocol.responseBody = Data("""
        {"ok":true,"items":[
          {"id":"svc_1","name":"Balayage","categoryId":"cat_hair","categoryName":"Hair","categorySlug":"hair"},
          {"id":"svc_2","name":"Gel Manicure","categoryId":null,"categoryName":null,"categorySlug":null}
        ],"nextCursor":"cur_2"}
        """.utf8)

        let page = try await DiscoverService(api: await makeAPI()).searchServices(q: "  bala  ")

        // The sibling route, NOT the unified /search?tab=SERVICES — the unified
        // one drops nextCursor, so it could never paginate.
        #expect(FeedDiscoveryURLProtocol.capturedPath == "/api/v1/search/services")
        #expect(queryItems()["q"] == "bala")
        #expect(page.nextCursor == "cur_2")
        #expect(page.items.count == 2)
        #expect(page.items.first?.name == "Balayage")
        #expect(page.items.first?.categoryName == "Hair")
        // An uncategorized service must decode, not blow up the page.
        #expect(page.items.last?.categoryId == nil)
    }

    /// Empty query = the browse list; the route falls back to the active catalog.
    @Test func searchServicesOmitsQForABlankQuery() async throws {
        reset()
        FeedDiscoveryURLProtocol.responseBody = Data("{\"ok\":true,\"items\":[],\"nextCursor\":null}".utf8)

        _ = try await DiscoverService(api: await makeAPI()).searchServices(q: "   ")

        #expect(queryItems()["q"] == nil)
        #expect(queryItems()["limit"] == "40")
    }

    // MARK: - Pros filtered by an exact service

    @Test func searchProsSendsServiceIdWhenAServiceIsPicked() async throws {
        reset()
        FeedDiscoveryURLProtocol.responseBody = Data("{\"ok\":true,\"items\":[],\"nextCursor\":null}".utf8)

        _ = try await DiscoverService(api: await makeAPI()).searchPros(
            lat: 32.7, lng: -117.1, serviceId: "svc_balayage"
        )

        #expect(FeedDiscoveryURLProtocol.capturedPath == "/api/v1/search/pros")
        #expect(queryItems()["serviceId"] == "svc_balayage")
    }

    /// Every pre-existing caller passes no serviceId; the query must stay exactly
    /// as it was so this change can't perturb the normal pro search.
    @Test func searchProsOmitsServiceIdWhenNil() async throws {
        reset()
        FeedDiscoveryURLProtocol.responseBody = Data("{\"ok\":true,\"items\":[],\"nextCursor\":null}".utf8)

        _ = try await DiscoverService(api: await makeAPI()).searchPros(lat: 32.7, lng: -117.1)

        #expect(queryItems()["serviceId"] == nil)
    }
}
