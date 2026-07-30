import Foundation
import Testing
@testable import TovisKit

// The pro calendar's LOCATION SCOPE (K4) — `GET /api/v1/pro/calendar?scope=`.
//
// 🔴 Why this exists: `Booking_no_active_professional_overlap` excludes on
// `professionalId` ALONE — there is no location term in the constraint — so the
// database treats a professional as ONE resource. A feed filtered to one location
// therefore renders free space that a job at another location already owns, and
// the pro is shown time they do not have. iOS had exactly that bug, because
// `ProCalendarService.calendar` sent `locationId` or nothing at all and the server
// reads "nothing" as the primary location.
//
// The JSON below is a VERBATIM capture from a live `GET /api/v1/pro/calendar`,
// driven against the local dev stack as the seeded pro with two bookable
// locations (a salon and a mobile base) and a mobile booking at 1pm local — the
// SAME range fetched three ways. It is not a hand-built mock of the shape these
// models hope for: a mock of the assumed shape passes while the real wire rots.
// [[wire-shape-vs-mock-drift]]
//
// What the capture pins that a mock would not: the narrow feed genuinely omits the
// mobile row (the bug, reproduced), the wide feed carries it, and BOTH answers
// echo which one you got.

/// Records the outgoing request and serves a canned envelope.
final class CalendarScopeURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedQuery: String?
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedQuery = request.url?.query

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

@Suite(.serialized) struct ProCalendarScopeTests {

    // MARK: - Captures

    /// `?scope=ALL` — one salon booking and the mobile one, side by side, with the
    /// `location` echo carrying the SALON (the viewport anchor, not a filter).
    private let allScopeCapture = """
    {
      "ok": true,
      "professionalId": "cmrbry44b0003po0d5f1fcs2u",
      "scope": "ALL",
      "location": {
        "id": "cmrbry47t000fpo0dz0kdy80z",
        "type": "SALON",
        "timeZone": "America/Los_Angeles",
        "timeZoneValid": true
      },
      "timeZone": "America/Los_Angeles",
      "viewportTimeZone": "America/Los_Angeles",
      "needsTimeZoneSetup": false,
      "range": {
        "from": "2026-07-29T07:00:00.000Z",
        "requestedTo": "2026-07-30T07:00:00.000Z",
        "effectiveTo": "2026-07-30T07:00:00.000Z",
        "clamped": false,
        "maxDays": 42
      },
      "events": [
        {
          "id": "cmrr6vdjg0033po3nn4o0s6dv",
          "kind": "BOOKING",
          "startsAt": "2026-07-29T16:15:00.000Z",
          "endsAt": "2026-07-29T17:00:00.000Z",
          "title": "Balayage",
          "clientName": "Test Client",
          "clientProfileId": null,
          "status": "ACCEPTED",
          "locationType": "SALON",
          "locationId": "cmrbry47t000fpo0dz0kdy80z",
          "durationMinutes": 30,
          "timeZone": "America/Los_Angeles",
          "timeZoneSource": "BOOKING_SNAPSHOT",
          "localDateKey": "2026-07-29",
          "viewLocalDateKey": "2026-07-29",
          "paymentBadge": {
            "kind": "DEPOSIT_PAID",
            "label": "Deposit paid $40.00",
            "tone": "info",
            "significant": true
          },
          "details": {
            "serviceName": "Balayage",
            "bufferMinutes": 15,
            "serviceItems": []
          }
        },
        {
          "id": "k4mobiletest0000000000001",
          "kind": "BOOKING",
          "startsAt": "2026-07-29T20:00:00.000Z",
          "endsAt": "2026-07-29T20:45:00.000Z",
          "title": "Balayage",
          "clientName": "Test Client",
          "clientProfileId": null,
          "status": "ACCEPTED",
          "locationType": "MOBILE",
          "locationId": "cmrr461ch0001pod6fiyvnppm",
          "durationMinutes": 30,
          "timeZone": "America/Los_Angeles",
          "timeZoneSource": "BOOKING_SNAPSHOT",
          "localDateKey": "2026-07-29",
          "viewLocalDateKey": "2026-07-29",
          "paymentBadge": {
            "kind": "DEPOSIT_PAID",
            "label": "Deposit paid $40.00",
            "tone": "info",
            "significant": true
          },
          "details": {
            "serviceName": "Balayage",
            "bufferMinutes": 15,
            "serviceItems": []
          }
        }
      ],
      "canSalon": true,
      "canMobile": true,
      "stats": {
        "todaysBookings": 4,
        "availableHours": null,
        "pendingRequests": 0,
        "blockedHours": 0
      },
      "blockedMinutesToday": 0,
      "autoAcceptBookings": false,
      "management": {
        "todaysBookings": [],
        "pendingRequests": [],
        "waitlistToday": [],
        "blockedToday": []
      }
    }
    """

    /// The SAME range with no scope at all — what iOS used to send. The 1pm mobile
    /// booking is simply absent: this is the bug, captured off the live route.
    private let narrowCapture = """
    {
      "ok": true,
      "professionalId": "cmrbry44b0003po0d5f1fcs2u",
      "scope": "LOCATION",
      "location": {
        "id": "cmrbry47t000fpo0dz0kdy80z",
        "type": "SALON",
        "timeZone": "America/Los_Angeles",
        "timeZoneValid": true
      },
      "timeZone": "America/Los_Angeles",
      "viewportTimeZone": "America/Los_Angeles",
      "needsTimeZoneSetup": false,
      "events": [
        {
          "id": "cmrr6vdjg0033po3nn4o0s6dv",
          "kind": "BOOKING",
          "startsAt": "2026-07-29T16:15:00.000Z",
          "endsAt": "2026-07-29T17:00:00.000Z",
          "title": "Balayage",
          "clientName": "Test Client",
          "clientProfileId": null,
          "status": "ACCEPTED",
          "locationType": "SALON",
          "locationId": "cmrbry47t000fpo0dz0kdy80z",
          "durationMinutes": 30,
          "timeZone": "America/Los_Angeles",
          "timeZoneSource": "BOOKING_SNAPSHOT",
          "localDateKey": "2026-07-29",
          "viewLocalDateKey": "2026-07-29",
          "paymentBadge": {
            "kind": "DEPOSIT_PAID",
            "label": "Deposit paid $40.00",
            "tone": "info",
            "significant": true
          },
          "details": {
            "serviceName": "Balayage",
            "bufferMinutes": 15,
            "serviceItems": []
          }
        }
      ],
      "stats": {
        "todaysBookings": 4,
        "availableHours": null,
        "pendingRequests": 0,
        "blockedHours": 0
      },
      "autoAcceptBookings": false,
      "management": {
        "todaysBookings": [],
        "pendingRequests": [],
        "waitlistToday": [],
        "blockedToday": []
      }
    }
    """

    private func decode(_ json: String) throws -> ProCalendarResponse {
        try JSONDecoder().decode(ProCalendarResponse.self, from: Data(json.utf8))
    }

    // MARK: - The scope echo

    @Test("an ALL-scope feed says so, and carries the other location's job")
    func decodesAllScope() throws {
        let response = try decode(allScopeCapture)

        #expect(response.scope == "ALL")
        #expect(response.isAllLocations)

        // The whole point: two locations in one feed, each event saying where it is.
        let locationIds = Set(response.events.compactMap(\.locationId))
        #expect(locationIds == ["cmrbry47t000fpo0dz0kdy80z", "cmrr461ch0001pod6fiyvnppm"])
        #expect(response.events.contains { $0.locationType == "MOBILE" })
    }

    @Test("the old narrow feed reads as filtered, and is missing the mobile job")
    func decodesLocationScope() throws {
        let response = try decode(narrowCapture)

        #expect(response.scope == "LOCATION")
        #expect(!response.isAllLocations)
        // Reproduces the bug this step fixes: the pro's 1pm is occupied by a mobile
        // booking the DB would refuse to double-book, and it is not in this feed.
        #expect(response.events.count == 1)
        #expect(!response.events.contains { $0.locationType == "MOBILE" })
    }

    @Test("a server with NO scope field is treated as filtered, never as everything")
    func absentScopeIsNotAllLocations() throws {
        // A build of the app can outrun the deploy: `scope` did not exist before
        // K3, and that server always answered for ONE location. Reading an absent
        // echo as "everything" would claim a mixed feed over a narrow one — the
        // same lie as the bug, told by the client instead of the server.
        var object = try JSONSerialization.jsonObject(
            with: Data(narrowCapture.utf8)) as! [String: Any]
        object.removeValue(forKey: "scope")
        let body = try JSONSerialization.data(withJSONObject: object)

        let response = try JSONDecoder().decode(ProCalendarResponse.self, from: body)

        #expect(response.scope == nil)
        #expect(!response.isAllLocations)
    }

    @Test("an unexpected scope value is not ALL either")
    func unknownScopeIsNotAllLocations() throws {
        let body = narrowCapture.replacingOccurrences(
            of: "\"scope\": \"LOCATION\"", with: "\"scope\": \"SOMETHING_NEW\"")

        let response = try decode(body)

        #expect(!response.isAllLocations)
    }

    // MARK: - What the service actually sends

    private func makeService() async -> ProCalendarService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CalendarScopeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.calendarscope.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProCalendarService(api: api)
    }

    @Test("the request carries scope=ALL — the param whose absence WAS the bug")
    func sendsAllScope() async throws {
        let service = await makeService()
        CalendarScopeURLProtocol.capturedQuery = nil
        CalendarScopeURLProtocol.responseBody = Data(allScopeCapture.utf8)

        _ = try await service.calendar(
            from: "2026-07-29T07:00:00Z", to: "2026-07-30T07:00:00Z", scope: .allLocations)

        let query = CalendarScopeURLProtocol.capturedQuery ?? ""
        #expect(query.contains("scope=ALL"))
        // The old param is gone: sending both would work (the route prefers
        // `scope`), but sending neither is what produced the narrow feed.
        #expect(!query.contains("locationId"))
    }

    @Test("a pro-chosen filter sends that location id as the scope")
    func sendsLocationScope() async throws {
        let service = await makeService()
        CalendarScopeURLProtocol.capturedQuery = nil
        CalendarScopeURLProtocol.responseBody = Data(narrowCapture.utf8)

        _ = try await service.calendar(
            from: "2026-07-29T07:00:00Z", to: "2026-07-30T07:00:00Z",
            scope: .location("cmrbry47t000fpo0dz0kdy80z"))

        let query = CalendarScopeURLProtocol.capturedQuery ?? ""
        #expect(query.contains("scope=cmrbry47t000fpo0dz0kdy80z"))
    }
}
