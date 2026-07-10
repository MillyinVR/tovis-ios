import Foundation
import Testing
@testable import TovisKit

// Proves the pro manual-reminders methods hit the right routes with the right
// verbs and bodies (all existing web routes — an iOS-only port):
//   • list     → GET  /api/v1/pro/reminders → decodes open + completed rows,
//                nested client + booking, missing optionals → nil
//   • create   → POST /api/v1/pro/reminders as application/x-www-form-urlencoded
//                (the route parses req.formData(), not JSON); optional body/clientId
//                are omitted when empty; decodes the created id
//   • complete → POST /api/v1/pro/reminders/{id}/complete → 2xx (JSON id echo)

/// Records the outgoing request and serves a canned envelope.
final class ProRemindersURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var capturedContentType: String?
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedBody = request.httpBody ?? request.reminderBodyStreamData()
        Self.capturedContentType = request.value(forHTTPHeaderField: "Content-Type")

        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// URLSession moves a POST body onto `httpBodyStream`; drain it for assertions.
    func reminderBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ProRemindersTests {
    private static let listJSON = """
    {
      "ok": true,
      "reminders": [
        {
          "id": "rem_1",
          "title": "Check in on color fade",
          "body": "ask how her scalp handled the lightening",
          "type": "GENERAL",
          "dueAt": "2026-07-15T17:00:00.000Z",
          "completedAt": null,
          "client": {"id": "cli_1", "firstName": "Dana", "lastName": "Rivers"},
          "booking": {
            "scheduledFor": "2026-07-20T15:00:00.000Z",
            "locationTimeZone": "America/Los_Angeles",
            "service": {"name": "Balayage"}
          }
        },
        {
          "id": "rem_2",
          "title": "DM bridal party count",
          "body": null,
          "type": "REBOOK",
          "dueAt": "2026-07-10T17:00:00.000Z",
          "completedAt": "2026-07-11T18:00:00.000Z",
          "client": null,
          "booking": null
        }
      ]
    }
    """

    private func makeService() async -> ProRemindersService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProRemindersURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.reminders.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProRemindersService(api: api)
    }

    private func reset(response: String) {
        ProRemindersURLProtocol.capturedPath = nil
        ProRemindersURLProtocol.capturedMethod = nil
        ProRemindersURLProtocol.capturedBody = nil
        ProRemindersURLProtocol.capturedContentType = nil
        ProRemindersURLProtocol.responseBody = Data(response.utf8)
    }

    /// Parse a captured `a=b&c=d` form body into a percent-decoded dictionary.
    private func formFields() throws -> [String: String] {
        let body = try #require(ProRemindersURLProtocol.capturedBody)
        let raw = try #require(String(data: body, encoding: .utf8))
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let key = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            out[String(key).removingPercentEncoding ?? String(key)] =
                value.removingPercentEncoding ?? value
        }
        return out
    }

    @Test func listGetsAndDecodesReminders() async throws {
        reset(response: Self.listJSON)

        let reminders = try await makeService().list()

        #expect(ProRemindersURLProtocol.capturedPath == "/api/v1/pro/reminders")
        #expect(ProRemindersURLProtocol.capturedMethod == "GET")

        #expect(reminders.count == 2)

        let open = try #require(reminders.first)
        #expect(open.id == "rem_1")
        #expect(open.title == "Check in on color fade")
        #expect(open.type == "GENERAL")
        #expect(open.isCompleted == false)
        #expect(open.client?.displayName == "Dana Rivers")
        #expect(open.booking?.service?.name == "Balayage")
        #expect(open.booking?.locationTimeZone == "America/Los_Angeles")

        let done = reminders[1]
        #expect(done.id == "rem_2")
        #expect(done.type == "REBOOK")
        #expect(done.isCompleted)          // completedAt present
        #expect(done.body == nil)          // missing optional → nil
        #expect(done.client == nil)        // unlinked
        #expect(done.booking == nil)
    }

    @Test func createPostsFormEncodedBodyAndDecodesId() async throws {
        reset(response: "{\"ok\":true,\"id\":\"rem_new\"}")

        let id = try await makeService().create(
            title: "Follow up on retail purchase",
            body: "remind about purple shampoo",
            dueAt: "2026-07-15T17:00:00Z",
            clientId: "cli_1"
        )

        #expect(ProRemindersURLProtocol.capturedPath == "/api/v1/pro/reminders")
        #expect(ProRemindersURLProtocol.capturedMethod == "POST")
        // The route parses req.formData(), so the body is form-encoded, not JSON.
        #expect(
            ProRemindersURLProtocol.capturedContentType == "application/x-www-form-urlencoded"
        )

        let fields = try formFields()
        #expect(fields["title"] == "Follow up on retail purchase")
        #expect(fields["body"] == "remind about purple shampoo")
        #expect(fields["dueAt"] == "2026-07-15T17:00:00Z")
        #expect(fields["clientId"] == "cli_1")
        #expect(fields["type"] == "GENERAL")   // matches the web create form

        #expect(id == "rem_new")
    }

    @Test func createOmitsEmptyOptionalFields() async throws {
        reset(response: "{\"ok\":true,\"id\":\"rem_new\"}")

        _ = try await makeService().create(
            title: "Order more toner",
            body: nil,
            dueAt: "2026-07-15T17:00:00Z",
            clientId: nil
        )

        let fields = try formFields()
        #expect(fields["title"] == "Order more toner")
        #expect(fields["dueAt"] == "2026-07-15T17:00:00Z")
        #expect(fields["type"] == "GENERAL")
        // Absent optionals are dropped, not sent blank.
        #expect(fields["body"] == nil)
        #expect(fields["clientId"] == nil)
    }

    @Test func completePostsToCompleteRoute() async throws {
        reset(response: "{\"ok\":true,\"id\":\"rem_1\"}")

        try await makeService().complete(id: "rem_1")

        #expect(ProRemindersURLProtocol.capturedPath == "/api/v1/pro/reminders/rem_1/complete")
        #expect(ProRemindersURLProtocol.capturedMethod == "POST")
    }
}
