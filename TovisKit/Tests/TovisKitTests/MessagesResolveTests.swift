import Foundation
import Testing
@testable import TovisKit

// Proves the thread-resolution helpers used by the deep-link + pro→client entry
// points: openBookingThread / openClientThread POST /messages/resolve with the
// right context and return the resolved thread; thread(id:) is the plain list
// lookup the push deep-link uses.
//
// ⚠️ These tests used to stub resolve as `{"id":"thr_1"}` AND stub an inbox that
// always contained thr_1 — so they passed green while the real flow was broken.
// A thread being created right now has no messages, and the live inbox hides
// message-less threads, so the second request found nothing. The harness below
// models both halves for real: `resolveIncludesRow` picks the backend vintage,
// and `inboxThreadIds` can be EMPTY, which is what the server actually returns
// for a brand-new thread.

/// Routes /messages/resolve → a canned thread (capturing the POST body) and
/// /messages/threads → a configurable inbox list. Records every path requested
/// so a test can prove the inbox was never consulted.
final class MessagesResolveURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedResolveBody: [String: String] = [:]
    nonisolated(unsafe) static var resolvedThreadId: String? = "thr_1"
    /// Whether resolve answers with the whole inbox row (the deployed backend
    /// after this change) or just `{"id":"…"}` (every build before it).
    nonisolated(unsafe) static var resolveIncludesRow = true
    /// Thread ids the inbox list returns. Empty models the real server response
    /// for a thread with no messages.
    nonisolated(unsafe) static var inboxThreadIds: [String] = ["thr_1"]
    nonisolated(unsafe) static var requestedPaths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// One inbox row. Field-for-field the shape captured from the running route
    /// (POST /api/v1/messages/resolve, 2026-07-18) — including the null
    /// `lastMessageAt` and `_count.messages: 0` of a thread nobody has written in.
    static func threadRowJSON(id: String) -> String {
        """
        {"id":"\(id)","contextType":"BOOKING","contextId":"bk_9","bookingId":"bk_9",
        "serviceId":"svc_1","offeringId":null,"waitlistEntryId":null,
        "lastMessageAt":null,"lastMessagePreview":null,
        "updatedAt":"2026-07-18T23:41:56.721Z",
        "client":{"id":"cli_1","firstName":"Dana","lastName":"Rivers","avatarUrl":null},
        "professional":{"id":"pro_1","businessName":"Glow Studio","avatarUrl":null,
        "displayName":"Glow Studio"},
        "participants":[{"lastReadAt":null}],"isViewerPro":true,
        "eyebrow":"BOOKING CONFIRMED — Balayage — Sun 7:32 PM","isAccentContext":true,
        "_count":{"messages":0}}
        """
    }

    private func readBody() -> Data {
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.requestedPaths.append(path)
        let body: Data

        if path.hasSuffix("/messages/resolve") {
            if let obj = try? JSONSerialization.jsonObject(with: readBody()) as? [String: Any] {
                Self.capturedResolveBody = obj.compactMapValues { "\($0)" }
            }

            let threadJSON: String
            if let id = Self.resolvedThreadId {
                threadJSON = Self.resolveIncludesRow
                    ? Self.threadRowJSON(id: id)
                    : "{\"id\":\"\(id)\"}"
            } else {
                threadJSON = "null"
            }
            body = Data("{\"ok\":true,\"thread\":\(threadJSON)}".utf8)
        } else {
            let rows = Self.inboxThreadIds.map { Self.threadRowJSON(id: $0) }.joined(separator: ",")
            body = Data("{\"ok\":true,\"threads\":[\(rows)]}".utf8)
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
        MessagesResolveURLProtocol.resolveIncludesRow = true
        MessagesResolveURLProtocol.inboxThreadIds = ["thr_1"]
        MessagesResolveURLProtocol.requestedPaths = []
    }

    @Test func openBookingThreadResolvesBookingContext() async throws {
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

    @Test func openWaitlistThreadResolvesWaitlistContext() async throws {
        reset()
        let thread = try await makeService().openWaitlistThread(waitlistEntryId: "wle_7")

        #expect(MessagesResolveURLProtocol.capturedResolveBody["contextType"] == "WAITLIST")
        #expect(MessagesResolveURLProtocol.capturedResolveBody["contextId"] == "wle_7")
        // The backend derives client & pro from the entry — no extra ids sent.
        #expect(MessagesResolveURLProtocol.capturedResolveBody["professionalId"] == nil)
        #expect(MessagesResolveURLProtocol.capturedResolveBody["clientId"] == nil)
        #expect(thread?.id == "thr_1")
    }

    @Test func openProfileThreadResolvesProProfileContext() async throws {
        reset()
        let thread = try await makeService().openProfileThread(professionalId: "pro_1")

        #expect(MessagesResolveURLProtocol.capturedResolveBody["contextType"] == "PRO_PROFILE")
        #expect(MessagesResolveURLProtocol.capturedResolveBody["contextId"] == "pro_1")
        #expect(MessagesResolveURLProtocol.capturedResolveBody["professionalId"] == "pro_1")
        #expect(thread?.id == "thr_1")
    }

    // THE REGRESSION TEST. The inbox is empty — exactly what the server returns
    // for a thread that has no messages yet — and opening it must still work,
    // because the row rode back on the resolve response.
    @Test func openBookingThreadOpensABrandNewThreadTheInboxCannotSee() async throws {
        reset()
        MessagesResolveURLProtocol.inboxThreadIds = []

        let thread = try await makeService().openBookingThread(bookingId: "bk_9")

        let opened = try #require(thread)
        #expect(opened.id == "thr_1")
        #expect(opened.lastMessageAt == nil)
        // Everything ThreadView renders in its header came off the same call.
        #expect(opened.counterpartyName == "Dana Rivers")
        #expect(opened.isViewerPro)
        #expect(opened.contextDestination == .booking(id: "bk_9"))
    }

    @Test func openBookingThreadDoesNotFetchTheInboxWhenTheRowIsPresent() async throws {
        reset()
        _ = try await makeService().openBookingThread(bookingId: "bk_9")

        // One round trip, not two: resolve carried the row.
        #expect(MessagesResolveURLProtocol.requestedPaths.count == 1)
        #expect(
            MessagesResolveURLProtocol.requestedPaths.allSatisfy {
                $0.hasSuffix("/messages/resolve")
            }
        )
    }

    // Back-compat: the currently deployed API answers `{"id":"…"}` with no row.
    // That must keep working exactly as before rather than failing to decode.
    @Test func fallsBackToTheInboxLookupAgainstAnOlderBackend() async throws {
        reset()
        MessagesResolveURLProtocol.resolveIncludesRow = false

        let thread = try await makeService().openBookingThread(bookingId: "bk_9")

        #expect(thread?.id == "thr_1")
        #expect(MessagesResolveURLProtocol.requestedPaths.count == 2)
        #expect(MessagesResolveURLProtocol.requestedPaths.last?.hasSuffix("/messages/threads") == true)
    }

    // The old behaviour, pinned so the fallback's blind spot stays visible: an
    // older backend plus a message-less thread finds nothing. Nothing on the
    // client can fix that — only the row on the resolve response can.
    @Test func olderBackendStillCannotOpenAThreadWithNoMessages() async throws {
        reset()
        MessagesResolveURLProtocol.resolveIncludesRow = false
        MessagesResolveURLProtocol.inboxThreadIds = []

        let thread = try await makeService().openBookingThread(bookingId: "bk_9")

        #expect(thread == nil)
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

    @Test func resolveThreadStillReturnsJustTheId() async throws {
        reset()
        let id = try await makeService().resolveThread(
            contextType: "BOOKING",
            contextId: "bk_9"
        )
        #expect(id == "thr_1")
    }
}

@Suite struct ResolveThreadResponseDecodingTests {
    private func decode(_ json: String) throws -> ResolveThreadResponse {
        try JSONDecoder().decode(ResolveThreadResponse.self, from: Data(json.utf8))
    }

    @Test func decodesTheFullRowWhenTheBackendSendsIt() throws {
        let row = MessagesResolveURLProtocol.threadRowJSON(id: "thr_1")
        let response = try decode("{\"ok\":true,\"thread\":\(row)}")

        let resolved = try #require(response.thread)
        #expect(resolved.id == "thr_1")
        #expect(resolved.row?.id == "thr_1")
        #expect(resolved.row?.eyebrow == "BOOKING CONFIRMED — Balayage — Sun 7:32 PM")
    }

    // An id-only payload must yield a usable id and a nil row — NOT a decode
    // error. This is what production answers until the web change deploys.
    @Test func decodesAnIdOnlyPayloadWithoutTheRow() throws {
        let response = try decode("{\"ok\":true,\"thread\":{\"id\":\"thr_1\"}}")

        let resolved = try #require(response.thread)
        #expect(resolved.id == "thr_1")
        #expect(resolved.row == nil)
    }

    // A row missing a field MessageThread requires degrades to the fallback
    // rather than throwing away the id (and with it the whole action).
    @Test func degradesToNilRowWhenTheRowIsIncomplete() throws {
        let response = try decode(
            "{\"ok\":true,\"thread\":{\"id\":\"thr_1\",\"isViewerPro\":true}}"
        )

        let resolved = try #require(response.thread)
        #expect(resolved.id == "thr_1")
        #expect(resolved.row == nil)
    }

    @Test func decodesAnAbsentThread() throws {
        #expect(try decode("{\"ok\":true,\"thread\":null}").thread == nil)
    }
}
