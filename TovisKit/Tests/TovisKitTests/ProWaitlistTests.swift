import Foundation
import Testing
@testable import TovisKit

// Proves the pro waitlist-outreach methods hit the right routes with the right
// verbs, bodies, and idempotency (all existing web routes — an iOS-only port):
//   • waitlistOutreach → GET  /api/v1/pro/waitlist → decodes services + entries + total
//   • offerWaitlistSlot → POST /api/v1/pro/waitlist/{entryId}/offer {slot + location}
//     + idempotency-key header → decodes the created PENDING offer
// The read feed's nested entries carry the FIFO rank, server-formatted preference
// label, and join instant; a missing avatar decodes to nil. The offer body sends
// only the chosen slot + in-salon location (the route derives client + service
// from the entry), always locationType SALON.

/// Records the outgoing request and serves a canned envelope.
final class ProWaitlistURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var capturedIdempotencyKey: String?
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)
    nonisolated(unsafe) static var responseStatus = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedBody = request.httpBody ?? request.waitlistBodyStreamData()
        Self.capturedIdempotencyKey = request.value(forHTTPHeaderField: "idempotency-key")

        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.responseStatus, httpVersion: nil,
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
    func waitlistBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ProWaitlistTests {
    private static let feedJSON = """
    {
      "ok": true,
      "total": 3,
      "services": [
        {
          "serviceId": "svc_1",
          "serviceName": "Balayage",
          "entries": [
            {"rank": 1, "waitlistEntryId": "wle_1", "clientName": "Dana Rivers",
             "avatarUrl": "https://cdn.tovis.me/a.jpg", "preferenceLabel": "Morning",
             "joinedAt": "2026-07-05T14:00:00.000Z"},
            {"rank": 2, "waitlistEntryId": "wle_2", "clientName": "Client",
             "avatarUrl": null, "preferenceLabel": "Any time",
             "joinedAt": "2026-07-06T14:00:00.000Z"}
          ]
        },
        {
          "serviceId": "svc_2",
          "serviceName": "Cut",
          "entries": [
            {"rank": 1, "waitlistEntryId": "wle_3", "clientName": "Sam Lee",
             "avatarUrl": null, "preferenceLabel": "9:00 AM–12:00 PM",
             "joinedAt": "2026-07-07T14:00:00.000Z"}
          ]
        }
      ]
    }
    """

    private func makeService() async -> ProScheduleService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProWaitlistURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.waitlist.tests")
        await tokenStore.save("session.token.value")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return ProScheduleService(api: api)
    }

    private func reset(response: String, status: Int = 200) {
        ProWaitlistURLProtocol.capturedPath = nil
        ProWaitlistURLProtocol.capturedMethod = nil
        ProWaitlistURLProtocol.capturedBody = nil
        ProWaitlistURLProtocol.capturedIdempotencyKey = nil
        ProWaitlistURLProtocol.responseBody = Data(response.utf8)
        ProWaitlistURLProtocol.responseStatus = status
    }

    private func bodyJSON() throws -> [String: Any] {
        let body = try #require(ProWaitlistURLProtocol.capturedBody)
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    @Test func waitlistOutreachGetsAndDecodesGroups() async throws {
        reset(response: Self.feedJSON)

        let outreach = try await makeService().waitlistOutreach()

        #expect(ProWaitlistURLProtocol.capturedPath == "/api/v1/pro/waitlist")
        #expect(ProWaitlistURLProtocol.capturedMethod == "GET")

        #expect(outreach.total == 3)
        #expect(outreach.isEmpty == false)
        #expect(outreach.services.count == 2)

        let balayage = try #require(outreach.services.first)
        #expect(balayage.id == "svc_1")
        #expect(balayage.serviceName == "Balayage")
        #expect(balayage.entries.count == 2)

        let first = try #require(balayage.entries.first)
        #expect(first.rank == 1)
        #expect(first.id == "wle_1")
        #expect(first.clientName == "Dana Rivers")
        #expect(first.avatarUrl == "https://cdn.tovis.me/a.jpg")
        #expect(first.preferenceLabel == "Morning")

        // A missing avatar decodes to nil.
        #expect(balayage.entries.last?.avatarUrl == nil)
    }

    // A VERBATIM capture of GET /api/v1/pro/waitlist after the pro offered a
    // time (real route over HTTP, 2026-07-21). tovis-app F14 made the offer
    // RESERVE the slot with a BookingHold, so the row now stays listed —
    // NOTIFIED entries used to be filtered out and the client silently vanished
    // — and carries the offer the badge renders. If the server ever renames or
    // drops `pendingOffer`, the pro loses the only surface explaining why that
    // time is missing from their availability, and this goes red.
    private static let offeredFeedJSON = """
    {"ok":true,"services":[{"serviceId":"cmrvgv4m50009poa15mc0qw8t",\
    "serviceName":"Balayage","entries":[{"rank":1,\
    "waitlistEntryId":"cmrvgv4m9000fpoa13x7fbjj4","clientName":"Hetty Client",\
    "avatarUrl":null,"preferenceLabel":"Any time",\
    "joinedAt":"2026-07-22T02:31:50.817Z",\
    "pendingOffer":{"id":"cmrvgvvx70003po2tjp8znkox",\
    "startsAt":"2026-07-31T20:00:00.000Z","locationType":"SALON"}}]}],"total":1}
    """

    @Test func waitlistOutreachDecodesTheLiveOfferOnARow() async throws {
        reset(response: Self.offeredFeedJSON)

        let outreach = try await makeService().waitlistOutreach()
        let entry = try #require(outreach.services.first?.entries.first)

        let offer = try #require(entry.pendingOffer)
        #expect(offer.id == "cmrvgvvx70003po2tjp8znkox")
        #expect(offer.startsAt == "2026-07-31T20:00:00.000Z")
        #expect(offer.locationType == "SALON")
    }

    // The other half: a row with no live offer decodes to nil rather than
    // failing, so the "Offer a time" button is what renders. The base fixture
    // omits the key entirely, which is also what a pre-F14 server sends.
    @Test func waitlistOutreachDecodesAMissingOfferAsNil() async throws {
        reset(response: Self.feedJSON)

        let outreach = try await makeService().waitlistOutreach()
        let entry = try #require(outreach.services.first?.entries.first)

        #expect(entry.pendingOffer == nil)
    }

    @Test func waitlistOutreachDecodesEmptyFeed() async throws {
        reset(response: "{\"ok\":true,\"total\":0,\"services\":[]}")

        let outreach = try await makeService().waitlistOutreach()

        #expect(outreach.total == 0)
        #expect(outreach.isEmpty)
        #expect(outreach.services.isEmpty)
    }

    // The web server now refuses an off-hours offer at OFFER time rather than
    // letting the client hit it at Confirm (tovis-app F5). Nothing in the app
    // changed for it — but `ProWaitlistOfferSheet` renders `APIError.userMessage`
    // and nothing was watching that the pro's own words survive the wire, so the
    // refusal body below is a VERBATIM capture from the real route
    // (POST /api/v1/pro/waitlist/{id}/offer over HTTP, 2026-07-21). If the
    // server's error envelope ever moves the copy off `error`, the sheet would
    // silently fall back to "Something went wrong" and this goes red.
    @Test func offerWaitlistSlotSurfacesTheOffHoursRefusal() async throws {
        reset(
            response: """
            {"ok":false,"error":"That time is outside working hours.",\
            "code":"OUTSIDE_WORKING_HOURS","retryable":true,\
            "uiAction":"PICK_NEW_SLOT",\
            "message":"That time is outside working hours."}
            """,
            status: 400
        )

        await #expect(throws: APIError.self) {
            try await makeService().offerWaitlistSlot(
                waitlistEntryId: "wle_1",
                scheduledFor: "2026-07-15T04:00:00.000Z",
                endsAt: "2026-07-15T05:00:00.000Z",
                locationId: "loc_1",
                durationMinutes: 60
            )
        }

        do {
            _ = try await makeService().offerWaitlistSlot(
                waitlistEntryId: "wle_1",
                scheduledFor: "2026-07-15T04:00:00.000Z",
                endsAt: "2026-07-15T05:00:00.000Z",
                locationId: "loc_1",
                durationMinutes: 60
            )
            Issue.record("expected the off-hours offer to throw")
        } catch let error as APIError {
            // This exact string is what the sheet paints in ember, inline, with
            // the slot picker still live behind it.
            #expect(error.userMessage == "That time is outside working hours.")
            guard case let .server(status, _, code) = error else {
                Issue.record("expected APIError.server, got \(error)")
                return
            }
            #expect(status == 400)
            #expect(code == "OUTSIDE_WORKING_HOURS")
        }
    }

    @Test func offerWaitlistSlotPostsSlotAndDecodesOffer() async throws {
        reset(response: """
        {"ok":true,"offer":{"id":"wof_1","status":"PENDING",
         "startsAt":"2026-07-15T17:00:00.000Z","endsAt":"2026-07-15T18:00:00.000Z",
         "locationType":"SALON"}}
        """)

        let offer = try await makeService().offerWaitlistSlot(
            waitlistEntryId: "wle_1",
            scheduledFor: "2026-07-15T17:00:00.000Z",
            endsAt: "2026-07-15T18:00:00.000Z",
            locationId: "loc_1",
            durationMinutes: 60
        )

        #expect(ProWaitlistURLProtocol.capturedPath == "/api/v1/pro/waitlist/wle_1/offer")
        #expect(ProWaitlistURLProtocol.capturedMethod == "POST")

        // The route rejects a missing idempotency-key header, so one is always sent,
        // and it mirrors web exactly: scope + entry + the ISO start as the action
        // (no nonce) — so the same entry+slot dedupes while a different slot mints a
        // fresh key. Reconstruct it (same ~60s bucket) to pin that wiring.
        let key = try #require(ProWaitlistURLProtocol.capturedIdempotencyKey)
        #expect(key.split(separator: ":").count == 5)
        #expect(key == buildClientIdempotencyKey(
            scope: "pro-waitlist-offer",
            entityId: "wle_1",
            action: "2026-07-15T17:00:00.000Z"))

        // Body carries only the slot + in-salon location; always SALON.
        let json = try bodyJSON()
        #expect(json["scheduledFor"] as? String == "2026-07-15T17:00:00.000Z")
        #expect(json["endsAt"] as? String == "2026-07-15T18:00:00.000Z")
        #expect(json["locationId"] as? String == "loc_1")
        #expect(json["locationType"] as? String == "SALON")
        #expect(json["durationMinutes"] as? Int == 60)
        // Neither the client nor the service is sent — the route derives both.
        #expect(json["clientId"] == nil)
        #expect(json["serviceId"] == nil)

        #expect(offer.id == "wof_1")
        #expect(offer.status == "PENDING")
        #expect(offer.startsAt == "2026-07-15T17:00:00.000Z")
        #expect(offer.endsAt == "2026-07-15T18:00:00.000Z")
        #expect(offer.locationType == "SALON")
    }
}
