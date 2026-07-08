import Foundation
import Testing
@testable import TovisKit

// Proves MessagesService's attachment path: presignAttachment hits POST
// .../uploads and decodes the upload target; send(...) includes an `attachments`
// key only when paths are passed (byte-identical to before for text-only sends).

/// Records the outgoing request (method, path, body) and serves a canned reply.
final class MessagesAttachmentURLProtocol: URLProtocol {
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
        // URLProtocol strips httpBody for some methods; read the stream too.
        if let body = request.httpBody {
            Self.capturedBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            Self.capturedBody = data
        }

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

@Suite(.serialized) struct MessagesAttachmentTests {
    private func makeService() async -> MessagesService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MessagesAttachmentURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.messagesattach.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return MessagesService(api: api)
    }

    private func reset(_ body: String) {
        MessagesAttachmentURLProtocol.capturedPath = nil
        MessagesAttachmentURLProtocol.capturedMethod = nil
        MessagesAttachmentURLProtocol.capturedBody = nil
        MessagesAttachmentURLProtocol.status = 200
        MessagesAttachmentURLProtocol.responseBody = Data(body.utf8)
    }

    private func bodyObject() throws -> [String: Any] {
        let data = try #require(MessagesAttachmentURLProtocol.capturedBody)
        let json = try JSONSerialization.jsonObject(with: data)
        return try #require(json as? [String: Any])
    }

    @Test func presignPostsToUploadsAndDecodesTarget() async throws {
        reset("""
        {"ok":true,"bucket":"media-private","path":"messages/thr_1/u_1/x.jpg",
        "token":"tok_abc","signedUrl":"https://signed/upload"}
        """)

        let target = try await makeService().presignAttachment(
            threadId: "thr_1", contentType: "image/jpeg", size: 1234
        )

        #expect(MessagesAttachmentURLProtocol.capturedMethod == "POST")
        #expect(MessagesAttachmentURLProtocol.capturedPath == "/api/v1/messages/threads/thr_1/uploads")
        #expect(target.bucket == "media-private")
        #expect(target.path == "messages/thr_1/u_1/x.jpg")
        #expect(target.token == "tok_abc")

        let body = try bodyObject()
        #expect(body["contentType"] as? String == "image/jpeg")
        #expect(body["size"] as? Int == 1234)
    }

    @Test func sendIncludesAttachmentsWhenProvided() async throws {
        reset("""
        {"ok":true,"message":{"id":"m_1","body":"","createdAt":"2026-07-08T18:00:00.000Z",
        "senderUserId":"u_1","attachments":[{"id":"a_1","url":"https://signed/read","mediaType":"IMAGE"}]}}
        """)

        let created = try await makeService().send(
            threadId: "thr_1", body: "", attachmentPaths: ["messages/thr_1/u_1/x.jpg"]
        )

        #expect(MessagesAttachmentURLProtocol.capturedPath == "/api/v1/messages/threads/thr_1")
        let body = try bodyObject()
        let attachments = try #require(body["attachments"] as? [String])
        #expect(attachments == ["messages/thr_1/u_1/x.jpg"])
        #expect(created.attachments?.first?.url == "https://signed/read")
    }

    @Test func sendOmitsAttachmentsKeyForTextOnly() async throws {
        reset("""
        {"ok":true,"message":{"id":"m_1","body":"hi","createdAt":"2026-07-08T18:00:00.000Z",
        "senderUserId":"u_1","attachments":[]}}
        """)

        _ = try await makeService().send(threadId: "thr_1", body: "hi")

        let body = try bodyObject()
        #expect(body["body"] as? String == "hi")
        // Text-only send stays byte-identical: no attachments key at all.
        #expect(body["attachments"] == nil)
    }
}
