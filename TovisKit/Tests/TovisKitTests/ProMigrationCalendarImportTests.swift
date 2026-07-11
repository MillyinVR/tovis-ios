import Foundation
import Testing
@testable import TovisKit

// Proves the migration wizard's calendar-import methods hit the right routes with
// the right verbs + bodies and decode the fetch/preview/commit/subscription
// envelopes (existing web routes, POST-only, no DTO — an iOS-only port):
//   • fetchCalendarFeed           → POST /pro/migrate/calendar/fetch        { url } → { ics }
//   • previewCalendarImport       → POST /pro/migrate/calendar/preview       { ics } (no excludeUids) → { rows, summary }
//   • commitCalendarImport        → POST /pro/migrate/calendar/commit        { ics, excludeUids } → { created, skipped, failed }
//   • connectCalendarSubscription → POST /pro/migrate/calendar/subscription  { url } → { subscription }
//   • 404 while ENABLE_PRO_MIGRATION is off → APIError.server(404) (build-dark)

/// Records the outgoing request (incl. POST body) and serves a canned envelope.
final class CalendarImportURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedContentType: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedContentType = request.value(forHTTPHeaderField: "Content-Type")
        Self.capturedBody = request.httpBody ?? request.calendarImportBodyStreamData()

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
    /// URLSession moves a POST body onto `httpBodyStream`; drain it for assertions.
    func calendarImportBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ProMigrationCalendarImportTests {
    private func makeService() async -> ProMigrationService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CalendarImportURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.calendarimport.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProMigrationService(api: api)
    }

    private func reset(response: String) {
        CalendarImportURLProtocol.capturedPath = nil
        CalendarImportURLProtocol.capturedMethod = nil
        CalendarImportURLProtocol.capturedContentType = nil
        CalendarImportURLProtocol.capturedBody = nil
        CalendarImportURLProtocol.status = 200
        CalendarImportURLProtocol.responseBody = Data(response.utf8)
    }

    /// Decode the captured POST body into a JSON dictionary for key-level asserts.
    private func bodyJSON() throws -> [String: Any] {
        let body = try #require(CalendarImportURLProtocol.capturedBody)
        let obj = try JSONSerialization.jsonObject(with: body)
        return try #require(obj as? [String: Any])
    }

    // MARK: - Fetch

    @Test func fetchPostsUrlAndDecodesIcs() async throws {
        reset(response: "{\"ok\":true,\"ics\":\"BEGIN:VCALENDAR\\nEND:VCALENDAR\"}")

        let response = try await makeService().fetchCalendarFeed(url: "https://cal.example.com/feed.ics")

        #expect(CalendarImportURLProtocol.capturedPath == "/api/v1/pro/migrate/calendar/fetch")
        #expect(CalendarImportURLProtocol.capturedMethod == "POST")
        #expect(CalendarImportURLProtocol.capturedContentType == "application/json")
        let json = try bodyJSON()
        #expect(json["url"] as? String == "https://cal.example.com/feed.ics")
        #expect(response.ics.contains("VCALENDAR"))
    }

    // MARK: - Preview

    private static let previewJSON = """
    {
      "ok": true,
      "rows": [
        {
          "uid": "evt-1", "summary": "Balayage — Jane Doe",
          "start": "2026-08-01T15:00:00.000Z", "end": "2026-08-01T17:00:00.000Z",
          "classification": "BOOKING",
          "matchedServiceId": "svc_1", "matchedServiceName": "Balayage",
          "clientName": "Jane Doe", "isRecurring": false,
          "reason": "Matched to Balayage — will create an appointment."
        },
        {
          "uid": "evt-2", "summary": "Blocked",
          "start": "2026-08-02T18:00:00.000Z", "end": null,
          "classification": "BLOCK",
          "matchedServiceId": null, "matchedServiceName": null,
          "clientName": null, "isRecurring": false,
          "reason": "No matching service — time blocked."
        },
        {
          "uid": "evt-3", "summary": "Old cut",
          "start": "2020-01-01T15:00:00.000Z", "end": "2020-01-01T16:00:00.000Z",
          "classification": "SKIP",
          "matchedServiceId": null, "matchedServiceName": null,
          "clientName": null, "isRecurring": false,
          "reason": "Past appointment with no identifiable client — skipped."
        }
      ],
      "summary": { "total": 3, "bookings": 1, "blocks": 1, "history": 0, "skipped": 1 }
    }
    """

    @Test func previewPostsIcsWithoutExcludeUidsAndDecodes() async throws {
        reset(response: Self.previewJSON)

        let preview = try await makeService().previewCalendarImport(ics: "BEGIN:VCALENDAR\nEND:VCALENDAR")

        #expect(CalendarImportURLProtocol.capturedPath == "/api/v1/pro/migrate/calendar/preview")
        #expect(CalendarImportURLProtocol.capturedMethod == "POST")

        // Body carries the raw ics, and NO excludeUids for preview (encodeIfPresent).
        let json = try bodyJSON()
        #expect(json["ics"] as? String == "BEGIN:VCALENDAR\nEND:VCALENDAR")
        #expect(json["excludeUids"] == nil)

        // Decoded preview + derived helpers.
        #expect(preview.rows.count == 3)
        #expect(preview.summary.total == 3)
        #expect(preview.summary.bookings == 1)
        #expect(preview.summary.blocks == 1)
        #expect(preview.summary.skipped == 1)

        let booking = try #require(preview.rows.first)
        #expect(booking.kind == .booking)
        #expect(booking.title == "Jane Doe") // client name preferred
        #expect(booking.matchedServiceName == "Balayage")
        #expect(booking.end == "2026-08-01T17:00:00.000Z")

        let block = preview.rows[1]
        #expect(block.kind == .block)
        #expect(block.title == "Blocked") // no client → summary
        #expect(block.end == nil)
        #expect(block.matchedServiceId == nil)

        let skip = preview.rows[2]
        #expect(skip.kind == .skip)
    }

    // MARK: - Commit

    @Test func commitPostsExcludeUidsAndDecodes() async throws {
        reset(response: """
        {
          "ok": true,
          "created": { "bookings": 2, "blocks": 1, "history": 3 },
          "skipped": 1, "failed": 0
        }
        """)

        let result = try await makeService().commitCalendarImport(
            ics: "BEGIN:VCALENDAR\nEND:VCALENDAR",
            excludeUids: ["evt-2", "evt-5"]
        )

        #expect(CalendarImportURLProtocol.capturedPath == "/api/v1/pro/migrate/calendar/commit")
        #expect(CalendarImportURLProtocol.capturedMethod == "POST")

        let json = try bodyJSON()
        #expect(json["ics"] as? String == "BEGIN:VCALENDAR\nEND:VCALENDAR")
        let excludes = try #require(json["excludeUids"] as? [String])
        #expect(excludes == ["evt-2", "evt-5"])

        #expect(result.created.bookings == 2)
        #expect(result.created.blocks == 1)
        #expect(result.created.history == 3)
        #expect(result.skipped == 1)
        #expect(result.failed == 0)
    }

    // MARK: - Subscription

    @Test func connectSubscriptionPostsUrlAndDecodes() async throws {
        reset(response: """
        {
          "ok": true,
          "subscription": {
            "feedUrl": "https://cal.example.com/feed.ics",
            "status": "ACTIVE", "lastSyncedAt": null, "lastSyncError": null
          }
        }
        """)

        let subscription = try await makeService()
            .connectCalendarSubscription(url: "https://cal.example.com/feed.ics")

        #expect(CalendarImportURLProtocol.capturedPath == "/api/v1/pro/migrate/calendar/subscription")
        #expect(CalendarImportURLProtocol.capturedMethod == "POST")
        #expect(try bodyJSON()["url"] as? String == "https://cal.example.com/feed.ics")

        let sub = try #require(subscription)
        #expect(sub.feedUrl == "https://cal.example.com/feed.ics")
        #expect(sub.status == "ACTIVE")
        #expect(sub.lastSyncedAt == nil)
    }

    // MARK: - Build-dark 404

    @Test func previewThrowsServer404WhenFlagOff() async throws {
        reset(response: "{\"ok\":false,\"error\":\"Not found\"}")
        CalendarImportURLProtocol.status = 404

        do {
            _ = try await makeService().previewCalendarImport(ics: "BEGIN:VCALENDAR\nEND:VCALENDAR")
            Issue.record("expected a 404 to throw")
        } catch let error as APIError {
            guard case .server(404, _, _) = error else {
                Issue.record("expected APIError.server(404), got \(error)")
                return
            }
        }
    }
}
