import Foundation
import Testing
@testable import TovisKit

// Proves the thread-resolution helpers used by the deep-link + pro→client entry
// points: openBookingThread / openClientThread POST /messages/resolve with the
// right context, then GET /messages/threads and return the matching thread;
// thread(id:) is the plain list lookup the push deep-link uses.

/// Routes /messages/resolve → a canned thread id (capturing the POST body) and
/// /messages/threads → a one-thread list, so the resolve+find flow can run.
final class MessagesResolveURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedResolveBody: [String: String] = [:]
    nonisolated(unsafe) static var resolvedThreadId: String? = "thr_1"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body: Data

        if path.hasSuffix("/messages/resolve") {
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                buffer.deallocate()
                stream.close()
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    Self.capturedResolveBody = obj.compactMapValues { "\($0)" }
                }
            }
            let idJson = Self.resolvedThreadId.map { "{\"id\":\"\($0)\"}" } ?? "null"
            body = Data("{\"ok\":true,\"thread\":\(idJson)}".utf8)
        } else {
            // GET /messages/threads → a one-thread inbox list.
            body = Data("""
            {"ok":true,"threads":[{"id":"thr_1","updatedAt":"2026-07-15T12:00:00.000Z",
            "isViewerPro":true,"client":{"id":"cli_1","firstName":"Dana","lastName":"Rivers","avatarUrl":null},
            "professional":{"id":"pro_1","businessName":"Glow Studio","avatarUrl":null},
            "participants":[{"lastReadAt":null}]}]}
            """.utf8)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct MessagesResolveTests {
    private func makeService() async -> MessagesService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MessagesResolveURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.messagesresolve.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return MessagesService(api: api)
    }

    private func reset() {
        MessagesResolveURLProtocol.capturedResolveBody = [:]
        MessagesResolveURLProtocol.resolvedThreadId = "thr_1"
    }

    @Test func openBookingThreadResolvesBookingContextThenFindsThread() async throws {
        reset()
        let thread = try await makeService().openBookingThread(bookingId: "bk_9")

        #expect(MessagesResolveURLProtocol.capturedResolveBody["contextType"] == "BOOKING")
        #expect(MessagesResolveURLProtocol.capturedResolveBody["contextId"] == "bk_9")
        #expect(thread?.id == "thr_1")
    }

    @Test func openClientThreadResolvesProProfileWithOwnIdAndClient() async throws {
        reset()
        let thread = try await makeService().openClientThread(
            professionalId: "pro_1",
            clientId: "cli_1"
        )

        #expect(MessagesResolveURLProtocol.capturedResolveBody["contextType"] == "PRO_PROFILE")
        #expect(MessagesResolveURLProtocol.capturedResolveBody["contextId"] == "pro_1")
        #expect(MessagesResolveURLProtocol.capturedResolveBody["clientId"] == "cli_1")
        #expect(thread?.id == "thr_1")
    }

    @Test func openWaitlistThreadResolvesWaitlistContextThenFindsThread() async throws {
        reset()
        let thread = try await makeService().openWaitlistThread(waitlistEntryId: "wle_7")

        #expect(MessagesResolveURLProtocol.capturedResolveBody["contextType"] == "WAITLIST")
        #expect(MessagesResolveURLProtocol.capturedResolveBody["contextId"] == "wle_7")
        // The backend derives client & pro from the entry — no extra ids sent.
        #expect(MessagesResolveURLProtocol.capturedResolveBody["professionalId"] == nil)
        #expect(MessagesResolveURLProtocol.capturedResolveBody["clientId"] == nil)
        #expect(thread?.id == "thr_1")
    }

    @Test func threadByIdFindsItInTheList() async throws {
        reset()
        let thread = try await makeService().thread(id: "thr_1")
        #expect(thread?.id == "thr_1")

        let missing = try await makeService().thread(id: "nope")
        #expect(missing == nil)
    }

    @Test func openBookingThreadReturnsNilWhenResolveYieldsNoThread() async throws {
        reset()
        MessagesResolveURLProtocol.resolvedThreadId = nil
        let thread = try await makeService().openBookingThread(bookingId: "bk_9")
        #expect(thread == nil)
    }
}
