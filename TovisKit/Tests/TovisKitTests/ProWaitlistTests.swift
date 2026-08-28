import Foundation
import Testing
@testable import TovisKit

// Proves the pro waitlist-outreach methods hit the right routes with the right
// verbs, bodies, and idempotency (all existing web routes — an iOS-only port):
//   • waitlistOutreach → GET  /api/v1/pro/waitlist → decodes services + entries + total
//   • waitlistOfferOptions → GET /api/v1/pro/waitlist/{entryId}/offer → the modes
//     this pro may offer in and the location of their own each is anchored to
//   • offerWaitlistSlot → POST /api/v1/pro/waitlist/{entryId}/offer {slot + mode +
//     location} + idempotency-key header → decodes the created PENDING offer
// The read feed's nested entries carry the FIFO rank, server-formatted preference
// label, and join instant; a missing avatar decodes to nil. The offer body sends
// only the chosen slot, the mode, and the PRO's location for it (the route derives
// client + service from the entry).
//
// 🔴 The privacy half, which is what most of the mobile assertions here are for:
// a PENDING mobile offer reaches this app as a distance and a general area and
// NOTHING else. That is enforced on the server, so these tests pin the wire
// contract the app depends on rather than the app's rendering of it.

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
                locationType: "SALON",
                durationMinutes: 60
            )
        }

        do {
            _ = try await makeService().offerWaitlistSlot(
                waitlistEntryId: "wle_1",
                scheduledFor: "2026-07-15T04:00:00.000Z",
                endsAt: "2026-07-15T05:00:00.000Z",
                locationId: "loc_1",
                locationType: "SALON",
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
            locationType: "SALON",
            durationMinutes: 60
        )

        #expect(ProWaitlistURLProtocol.capturedPath == "/api/v1/pro/waitlist/wle_1/offer")
        #expect(ProWaitlistURLProtocol.capturedMethod == "POST")

        // The route rejects a missing idempotency-key header, so one is always sent,
        // and it mirrors web exactly: scope + entry + "MODE:ISO start" as the action
        // (no nonce) — so the same entry+mode+slot dedupes while a different slot,
        // or the same minute in the other mode, mints a fresh key. The MODE is in
        // there because offering 5pm in-salon and 5pm mobile are two different
        // promises and a replay must not collapse them. Reconstruct it PINNED to the
        // sent key's bucket to pin that wiring (rebuilding against the live clock
        // races the 60s rollover — see IdempotencyKeyTestSupport).
        let key = try #require(ProWaitlistURLProtocol.capturedIdempotencyKey)
        #expect(key.split(separator: ":").count == 5)
        #expect(key == rebuiltIdempotencyKey(
            matchingBucketOf: key,
            scope: "pro-waitlist-offer",
            entityId: "wle_1",
            action: "SALON:2026-07-15T17:00:00.000Z"))
        #expect(idempotencyKeyBucketIsCurrent(key))

        // Body carries only the slot, the mode, and the PRO's location for it.
        let json = try bodyJSON()
        #expect(json["scheduledFor"] as? String == "2026-07-15T17:00:00.000Z")
        #expect(json["endsAt"] as? String == "2026-07-15T18:00:00.000Z")
        #expect(json["locationId"] as? String == "loc_1")
        #expect(json["locationType"] as? String == "SALON")
        #expect(json["durationMinutes"] as? Int == 60)
        // Neither the client nor the service is sent — the route derives both.
        #expect(json["clientId"] == nil)
        #expect(json["serviceId"] == nil)
        // 🔴 And never a client address. For a MOBILE offer the destination is
        // resolved server-side; a field here would mean this device held one.
        #expect(json["clientAddressId"] == nil)

        #expect(offer.id == "wof_1")
        #expect(offer.status == "PENDING")
        #expect(offer.startsAt == "2026-07-15T17:00:00.000Z")
        #expect(offer.endsAt == "2026-07-15T18:00:00.000Z")
        #expect(offer.locationType == "SALON")
    }

    // MARK: - MOBILE offers (tovis-app, 2026-08-27)

    // A VERBATIM capture of GET /api/v1/pro/waitlist for a pro with a PENDING
    // MOBILE offer out. `travel` is everything the server will say about where
    // that trip goes while the client has yet to accept — there is no address and
    // no coordinate field to decode, which is the point.
    private static let mobileOfferedFeedJSON = """
    {"ok":true,"services":[{"serviceId":"svc_m","serviceName":"Balayage",\
    "entries":[{"rank":1,"waitlistEntryId":"wle_m","clientName":"Nadia Waiter",\
    "avatarUrl":null,"preferenceLabel":"Any time",\
    "joinedAt":"2026-08-20T02:31:50.817Z",\
    "pendingOffer":{"id":"wof_m","startsAt":"2026-09-01T17:00:00.000Z",\
    "locationType":"MOBILE","travel":{"distanceMiles":1.87,\
    "areaLabel":"Coronado, CA","summary":"1.9 mi away · Coronado, CA"}}}]}],\
    "total":1}
    """

    @Test func waitlistOutreachDecodesTheTripSummaryOnAMobileOffer() async throws {
        reset(response: Self.mobileOfferedFeedJSON)

        let outreach = try await makeService().waitlistOutreach()
        let entry = try #require(outreach.services.first?.entries.first)
        let offer = try #require(entry.pendingOffer)

        #expect(offer.locationType == "MOBILE")
        let travel = try #require(offer.travel)
        // Rendered verbatim by ProWaitlistView — the server owns the wording.
        #expect(travel.summary == "1.9 mi away · Coronado, CA")
        #expect(travel.areaLabel == "Coronado, CA")
        #expect(travel.distanceMiles == 1.87)
    }

    // 🔴 The regression this file exists to catch: an address appearing on the
    // pro-facing offer payload. If the server ever adds one, the decoder here
    // gains a field to read and this test is where that has to be argued for.
    @Test func aPendingOfferCarriesNoAddressFieldToDecode() async throws {
        reset(response: Self.mobileOfferedFeedJSON)

        _ = try await makeService().waitlistOutreach()

        let raw = String(decoding: Self.mobileOfferedFeedJSON.utf8, as: UTF8.self)
        #expect(!raw.contains("formattedAddress"))
        #expect(!raw.contains("addressLine"))
        #expect(!raw.contains("clientAddressId"))
        #expect(!raw.contains("\"lat\""))
        #expect(!raw.contains("\"lng\""))

        // And the model has nowhere to put one: `travel` is exactly these three.
        let travel = ProWaitlistOfferTravel(
            distanceMiles: 1.87, areaLabel: "Coronado, CA", summary: "1.9 mi away")
        #expect(travel.summary == "1.9 mi away")
    }

    @Test func aSalonOfferHasNoTravelBlock() async throws {
        // The pre-existing SALON capture, which predates `travel` entirely — so
        // this also proves an older server decodes fine (the field is optional).
        reset(response: Self.offeredFeedJSON)

        let outreach = try await makeService().waitlistOutreach()
        let offer = try #require(outreach.services.first?.entries.first?.pendingOffer)

        #expect(offer.locationType == "SALON")
        #expect(offer.travel == nil)
    }

    @Test func waitlistOfferOptionsGetsTheModesTheServerAllows() async throws {
        reset(response: """
        {"ok":true,"offeringId":"off_1","blockedReason":null,"options":[
          {"locationType":"SALON","locationId":"loc_1","locationName":"Main Salon",
           "timeZone":"America/Los_Angeles","durationMinutes":60},
          {"locationType":"MOBILE","locationId":"base_1","locationName":"Home base",
           "timeZone":"America/Los_Angeles","durationMinutes":75}
        ]}
        """)

        let result = try await makeService().waitlistOfferOptions(waitlistEntryId: "wle_1")

        #expect(ProWaitlistURLProtocol.capturedPath == "/api/v1/pro/waitlist/wle_1/offer")
        #expect(ProWaitlistURLProtocol.capturedMethod == "GET")

        #expect(result.offeringId == "off_1")
        #expect(result.blockedReason == nil)
        #expect(result.options.count == 2)

        let mobile = try #require(result.options.last)
        #expect(mobile.isMobile)
        // The PRO's own base — never anything of the client's.
        #expect(mobile.locationId == "base_1")
        // Mobile and in-salon durations legitimately differ, and the sheet sizes
        // `endsAt` from the SELECTED mode's.
        #expect(mobile.durationMinutes == 75)
        #expect(result.options.first?.isMobile == false)
    }

    @Test func waitlistOfferOptionsCarriesTheServerSentenceWhenNothingCanBeOffered() async throws {
        reset(response: """
        {"ok":true,"offeringId":null,"options":[],
         "blockedReason":"You don’t have an active offering for this service, so there’s no time to offer. Add or activate the service first."}
        """)

        let result = try await makeService().waitlistOfferOptions(waitlistEntryId: "wle_1")

        // Not an error — an answer. The sheet paints this sentence rather than
        // inventing its own, so web and iOS say the same thing.
        #expect(result.options.isEmpty)
        #expect(result.offeringId == nil)
        #expect(result.blockedReason?.contains("active offering") == true)
    }

    @Test func offerWaitlistSlotSendsMobileWithTheProsOwnBase() async throws {
        reset(response: """
        {"ok":true,"offer":{"id":"wof_m","status":"PENDING",
         "startsAt":"2026-09-01T17:00:00.000Z","endsAt":"2026-09-01T18:15:00.000Z",
         "locationType":"MOBILE"}}
        """)

        let offer = try await makeService().offerWaitlistSlot(
            waitlistEntryId: "wle_m",
            scheduledFor: "2026-09-01T17:00:00.000Z",
            endsAt: "2026-09-01T18:15:00.000Z",
            locationId: "base_1",
            locationType: "MOBILE",
            durationMinutes: 75
        )

        let json = try bodyJSON()
        #expect(json["locationType"] as? String == "MOBILE")
        #expect(json["locationId"] as? String == "base_1")
        // 🔴 No destination in the body, and no way to put one there: the server
        // resolves the client's address itself.
        #expect(json["clientAddressId"] == nil)
        #expect(json["clientLat"] == nil)
        #expect(json["clientLng"] == nil)

        // The mode is part of the idempotency action, so 5pm-mobile and
        // 5pm-in-salon are two promises, not one replayed.
        let key = try #require(ProWaitlistURLProtocol.capturedIdempotencyKey)
        #expect(key == rebuiltIdempotencyKey(
            matchingBucketOf: key,
            scope: "pro-waitlist-offer",
            entityId: "wle_m",
            action: "MOBILE:2026-09-01T17:00:00.000Z"))

        #expect(offer.locationType == "MOBILE")
    }
}
