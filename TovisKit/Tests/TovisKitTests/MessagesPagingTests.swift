import Foundation
import Testing
@testable import TovisKit

// Proves MessagesService.messages(threadId:cursor:) pages a thread's history:
// no cursor → the latest page (no query); a cursor → GET ?cursor=<id> for the
// older page, and the decoded page surfaces nextCursor/hasMore for "load earlier".

/// Serves a canned thread-messages page and records the outgoing request query.
final class MessagesPagingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedQuery: String?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedQuery = request.url?.query

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct MessagesPagingTests {
    private func makeService() async -> MessagesService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MessagesPagingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.messagespaging.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return MessagesService(api: api)
    }

    private func reset(_ body: String) {
        MessagesPagingURLProtocol.capturedPath = nil
        MessagesPagingURLProtocol.capturedQuery = nil
        MessagesPagingURLProtocol.status = 200
        MessagesPagingURLProtocol.responseBody = Data(body.utf8)
    }

    private let fullPage = """
    {"ok":true,"thread":{"id":"thr_1","isViewerPro":false,"counterpartyLastReadAt":null},
    "messages":[{"id":"m_10","body":"hi","createdAt":"2026-07-08T18:00:00.000Z","senderUserId":"u_1","attachments":[]}],
    "nextCursor":"m_10","hasMore":true,"take":40}
    """

    @Test func latestPageSendsNoCursorAndSurfacesHasMore() async throws {
        reset(fullPage)

        let page = try await makeService().messages(threadId: "thr_1")

        #expect(MessagesPagingURLProtocol.capturedPath == "/api/v1/messages/threads/thr_1")
        // No cursor → no query string (byte-identical to the pre-paging request).
        #expect((MessagesPagingURLProtocol.capturedQuery ?? "").isEmpty)
        #expect(page.messages.count == 1)
        #expect(page.nextCursor == "m_10")
        #expect(page.hasMore)
    }

    @Test func olderPageSendsCursorQuery() async throws {
        reset("""
        {"ok":true,"thread":{"id":"thr_1","isViewerPro":false,"counterpartyLastReadAt":null},
        "messages":[{"id":"m_1","body":"older","createdAt":"2026-07-08T17:00:00.000Z","senderUserId":"u_1","attachments":[]}],
        "nextCursor":null,"hasMore":false,"take":40}
        """)

        let page = try await makeService().messages(threadId: "thr_1", cursor: "m_10")

        #expect(MessagesPagingURLProtocol.capturedQuery == "cursor=m_10")
        #expect(page.messages.first?.id == "m_1")
        // Partial page → no more older history.
        #expect(page.nextCursor == nil)
        #expect(page.hasMore == false)
    }
}
