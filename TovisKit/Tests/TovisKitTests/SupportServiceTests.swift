import Foundation
import Testing
@testable import TovisKit

// Proves native support-ticket filing hits the right route with the right body:
//   • createTicket() → POST /support/tickets → { ticket }
// The authenticated-POST assertion is the point of the surface, not incidental:
// the ticket has no contact column, so the bearer user IS the admin queue's reply
// path. An unauthenticated submission (what a SafariView on /support would send)
// is exactly the bug this route exists to prevent.

/// Records the outgoing request and serves a canned envelope.
final class SupportURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedAuthHeader: String?
    nonisolated(unsafe) static var capturedContentType: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedAuthHeader = request.value(forHTTPHeaderField: "Authorization")
        Self.capturedContentType = request.value(forHTTPHeaderField: "Content-Type")
        Self.capturedBody = request.httpBody ?? request.supportBodyStreamData()

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
    func supportBodyStreamData() -> Data? {
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

@Suite(.serialized) struct SupportServiceTests {
    private func makeService() async -> SupportService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SupportURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.support.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return SupportService(api: api)
    }

    private func reset() {
        SupportURLProtocol.capturedPath = nil
        SupportURLProtocol.capturedMethod = nil
        SupportURLProtocol.capturedAuthHeader = nil
        SupportURLProtocol.capturedContentType = nil
        SupportURLProtocol.capturedBody = nil
        SupportURLProtocol.status = 200
        SupportURLProtocol.responseBody = Data("{\"ok\":true}".utf8)
    }

    private func decodeBody(_ data: Data?) throws -> [String: Any] {
        let body = try #require(data)
        let json = try JSONSerialization.jsonObject(with: body)
        return try #require(json as? [String: Any])
    }

    @Test func createTicketPostsSubjectAndMessageAuthenticated() async throws {
        reset()
        SupportURLProtocol.responseBody = Data("""
        {"ok":true,"ticket":{"id":"tkt_1","subject":"Booking not confirming","status":"OPEN","createdAt":"2026-07-16T18:51:19.769Z"}}
        """.utf8)

        let ticket = try await makeService().createTicket(
            subject: "Booking not confirming",
            message: "It spins forever on the confirm step."
        )

        #expect(SupportURLProtocol.capturedPath == "/api/v1/support/tickets")
        #expect(SupportURLProtocol.capturedMethod == "POST")
        #expect(SupportURLProtocol.capturedContentType == "application/json")
        // Without the bearer the ticket lands unattributed and unanswerable.
        #expect(SupportURLProtocol.capturedAuthHeader == "Bearer session.token.value")

        let sent = try decodeBody(SupportURLProtocol.capturedBody)
        #expect(sent["subject"] as? String == "Booking not confirming")
        #expect(sent["message"] as? String == "It spins forever on the confirm step.")

        #expect(ticket.id == "tkt_1")
        #expect(ticket.subject == "Booking not confirming")
        #expect(ticket.status == "OPEN")
    }

    @Test func createTicketSurfacesServerValidationCode() async throws {
        reset()
        SupportURLProtocol.status = 400
        SupportURLProtocol.responseBody = Data("""
        {"ok":false,"error":"Subject and message are required.","code":"MISSING_FIELDS"}
        """.utf8)

        await #expect(throws: APIError.server(
            status: 400,
            message: "Subject and message are required.",
            code: "MISSING_FIELDS"
        )) {
            _ = try await makeService().createTicket(subject: "", message: "")
        }
    }

    @Test func createTicketSurfacesRateLimit() async throws {
        reset()
        SupportURLProtocol.status = 429
        SupportURLProtocol.responseBody = Data("""
        {"ok":false,"error":"Too many requests. Please slow down.","code":"RATE_LIMITED"}
        """.utf8)

        // The form renders `userMessage`, so the server's copy is what a rate-limited
        // person actually reads — no native restatement of the ceiling.
        await #expect(throws: APIError.server(
            status: 429,
            message: "Too many requests. Please slow down.",
            code: "RATE_LIMITED"
        )) {
            _ = try await makeService().createTicket(subject: "s", message: "m")
        }
    }
}
