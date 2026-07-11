import Foundation
import Testing
@testable import TovisKit

// Proves the client aftercare-inbox surface on BookingsService:
//   • aftercareInbox() → GET /client/aftercare → { ok, items }  (envelope unwrapped)
//   • booking(id:)     → resolves a ClientBooking from the bucketed list (there is
//                        no single-booking client GET), so an inbox row can push
//                        the booking detail focused on the aftercare step.
// Rows are defensively decoded (title/pro/timeZone fallbacks, null beforeAfter →
// nil, unread default) and the hint discriminator mirrors web aftercareInboxHintMode.

/// Records the outgoing request and serves a canned envelope.
final class AftercareInboxURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
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

@Suite(.serialized) struct ClientAftercareInboxServiceTests {
    private func makeService() async -> BookingsService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AftercareInboxURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.aftercareinbox.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return BookingsService(api: api)
    }

    private func reset(_ body: Data = Data("{\"ok\":true}".utf8)) {
        AftercareInboxURLProtocol.capturedPath = nil
        AftercareInboxURLProtocol.capturedMethod = nil
        AftercareInboxURLProtocol.status = 200
        AftercareInboxURLProtocol.responseBody = body
    }

    // A rich two-row inbox: one fully-populated unread row + one sparse row that
    // exercises every defensive fallback (missing title/pro/timeZone, null pair).
    private let inboxJSON = """
    {
      "ok": true,
      "items": [
        {
          "notificationId": "ntf_1",
          "bookingId": "bk_1",
          "aftercareId": "ac_1",
          "title": "Balayage + Toner",
          "proId": "pro_1",
          "proName": "Glow Studio",
          "scheduledFor": "2026-07-09T14:30:00.000Z",
          "timeZone": "America/New_York",
          "beforeAfter": {
            "beforeUrl": "https://cdn/b.jpg",
            "afterUrl": "https://cdn/a.jpg",
            "beforeFullUrl": "https://cdn/bf.jpg",
            "afterFullUrl": "https://cdn/af.jpg"
          },
          "rebookMode": "RECOMMENDED_WINDOW",
          "rebookedFor": null,
          "body": "Wash after 48h.",
          "unread": true,
          "createdAt": "2026-07-09T15:00:00.000Z"
        },
        {
          "notificationId": "ntf_2",
          "bookingId": null,
          "aftercareId": null,
          "proId": null,
          "scheduledFor": null,
          "beforeAfter": null,
          "rebookMode": null,
          "rebookedFor": null,
          "body": null,
          "unread": false,
          "createdAt": "2026-07-01T10:00:00.000Z"
        }
      ]
    }
    """

    // MARK: - aftercareInbox()

    @Test func aftercareInboxHitsRouteAndUnwrapsEnvelope() async throws {
        reset(Data(inboxJSON.utf8))
        let service = await makeService()

        let items = try await service.aftercareInbox()

        #expect(AftercareInboxURLProtocol.capturedPath == "/api/v1/client/aftercare")
        #expect(AftercareInboxURLProtocol.capturedMethod == "GET")
        #expect(items.count == 2)

        let first = try #require(items.first)
        #expect(first.notificationId == "ntf_1")
        #expect(first.bookingId == "bk_1")
        #expect(first.title == "Balayage + Toner")
        #expect(first.proName == "Glow Studio")
        #expect(first.unread == true)
        #expect(first.beforeAfter?.beforeUrl == "https://cdn/b.jpg")
        #expect(first.hint == .recommendedWindow)
    }

    @Test func aftercareInboxDecodesFallbacksAndNullPair() async throws {
        reset(Data(inboxJSON.utf8))
        let service = await makeService()

        let items = try await service.aftercareInbox()
        let sparse = try #require(items.last)

        // Missing title/proName/timeZone fall back exactly like the web loader.
        #expect(sparse.title == "Aftercare")
        #expect(sparse.proName == "Your pro")
        #expect(sparse.timeZone == "UTC")
        #expect(sparse.bookingId == nil)
        #expect(sparse.beforeAfter == nil)
        #expect(sparse.unread == false)
        #expect(sparse.hint == .notes)
    }

    // MARK: - hint discriminator (pure)

    @Test func hintDiscriminatorMirrorsWeb() {
        func item(mode: String?, rebookedFor: String?) -> ClientAftercareInboxItem {
            ClientAftercareInboxItem(
                notificationId: "n", bookingId: nil, aftercareId: nil, title: "t",
                proId: nil, proName: "p", scheduledFor: nil, timeZone: "UTC",
                beforeAfter: nil, rebookMode: mode, rebookedFor: rebookedFor,
                body: nil, unread: false, createdAt: ""
            )
        }

        #expect(item(mode: "RECOMMENDED_WINDOW", rebookedFor: nil).hint == .recommendedWindow)
        #expect(item(mode: "NONE", rebookedFor: "2026-08-01T13:00:00.000Z").hint == .recommendedDate)
        #expect(item(mode: nil, rebookedFor: nil).hint == .notes)
        // A window recommendation wins even if a date is also present.
        #expect(item(mode: "RECOMMENDED_WINDOW", rebookedFor: "2026-08-01").hint == .recommendedWindow)
    }

    // MARK: - booking(id:) resolve from buckets

    @Test func bookingResolvesFromBucketsById() async throws {
        reset(try fixture("clientBookings"))
        let service = await makeService()

        let upcoming = try await service.booking(id: "bk_1")
        #expect(upcoming?.id == "bk_1")
        #expect(AftercareInboxURLProtocol.capturedPath == "/api/v1/client/bookings")

        let prebooked = try await service.booking(id: "bk_next")
        #expect(prebooked?.id == "bk_next")
    }

    @Test func bookingReturnsNilForWaitlistOrUnknownId() async throws {
        reset(try fixture("clientBookings"))
        let service = await makeService()

        // A waitlist entry isn't a ClientBooking, so it never resolves.
        let waitlist = try await service.booking(id: "wl_1")
        #expect(waitlist == nil)

        let unknown = try await service.booking(id: "does_not_exist")
        #expect(unknown == nil)
    }
}
