import Foundation
import Testing
@testable import TovisKit

// Proves the client priority-offers surface — the native counterpart to the web
// /client/offers page (priority offers + pro-proposed waitlist times):
//   • HomeService.priorityOffers()      → GET  /client/priority-offer      { ok, offers }
//   • BookingsService.waitlistOffers()  → GET  /client/waitlist-offers     { ok, offers }
//   • BookingsService.respondToWaitlistOffer → POST /client/waitlist-offers/{id}
//       body { action: CONFIRM|DECLINE }, idempotency-key header, decodes booking
//   • ClientPriorityOffer derivations (remaining / isExpired / isUrgent /
//     isBookable / countdownLabel) mirror the web OffersListClient.

/// Records the outgoing request and serves a canned envelope; captures the POST
/// body (URLProtocol moves httpBody into a stream) + the idempotency header.
final class OffersURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedIdempotencyKey: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedMethod = request.httpMethod
        Self.capturedIdempotencyKey = request.value(forHTTPHeaderField: "idempotency-key")
        Self.capturedBody = request.httpBody ?? request.offersBodyStreamData()

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
    func offersBodyStreamData() -> Data? {
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

@Suite(.serialized) struct ClientOffersServiceTests {
    private func makeAPI() async -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OffersURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.offers.tests")
        await tokenStore.save("session.token.value")
        return APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
    }

    private func reset(_ body: Data = Data("{\"ok\":true}".utf8)) {
        OffersURLProtocol.capturedPath = nil
        OffersURLProtocol.capturedMethod = nil
        OffersURLProtocol.capturedIdempotencyKey = nil
        OffersURLProtocol.capturedBody = nil
        OffersURLProtocol.status = 200
        OffersURLProtocol.responseBody = body
    }

    // MARK: - priorityOffers() route + envelope + flat ids

    private let priorityJSON = """
    {
      "ok": true,
      "offers": [
        {
          "recipientId": "rcp_1",
          "status": "PRIORITY_OFFERED",
          "expiresAt": "2026-07-11T18:30:00.000Z",
          "expired": false,
          "proName": "Glow Studio",
          "proHref": "/professionals/pro_1",
          "professionalId": "pro_1",
          "avatarUrl": "https://cdn/a.jpg",
          "serviceLabel": "Balayage",
          "serviceId": "svc_1",
          "offeringId": "off_1",
          "startAt": "2026-07-11T18:00:00.000Z",
          "endAt": "2026-07-11T19:00:00.000Z",
          "timeZone": "America/New_York",
          "locationType": "SALON",
          "note": "Grab it while it lasts",
          "incentiveLabel": "20% off",
          "claimHref": "/offerings/off_1?scheduledFor=2026-07-11T18:00:00.000Z"
        },
        {
          "recipientId": "rcp_2",
          "status": "PRIORITY_OFFERED",
          "expiresAt": null,
          "expired": false,
          "proName": "Your pro",
          "proHref": "/professionals/pro_2",
          "professionalId": "pro_2",
          "avatarUrl": null,
          "serviceLabel": "a service",
          "serviceId": null,
          "offeringId": null,
          "startAt": "2026-07-12T15:30:00.000Z",
          "endAt": null,
          "timeZone": "America/Los_Angeles",
          "locationType": "MOBILE",
          "note": null,
          "incentiveLabel": null,
          "claimHref": "/client"
        }
      ]
    }
    """

    @Test func priorityOffersHitsRouteAndDecodesFlatIds() async throws {
        reset(Data(priorityJSON.utf8))
        let home = HomeService(api: await makeAPI())

        let offers = try await home.priorityOffers()

        #expect(OffersURLProtocol.capturedPath == "/api/v1/client/priority-offer")
        #expect(OffersURLProtocol.capturedMethod == "GET")
        #expect(offers.count == 2)

        let first = try #require(offers.first)
        #expect(first.recipientId == "rcp_1")
        #expect(first.professionalId == "pro_1")
        #expect(first.serviceId == "svc_1")
        #expect(first.offeringId == "off_1")
        #expect(first.incentiveLabel == "20% off")
        #expect(first.isBookable)

        let second = try #require(offers.dropFirst().first)
        #expect(second.expiresAt == nil)
        #expect(!second.isBookable)   // no serviceId/offeringId → falls back to profile
    }

    // MARK: - waitlistOffers() route + envelope

    @Test func waitlistOffersHitsRouteAndUnwrapsEnvelope() async throws {
        let json = """
        {
          "ok": true,
          "offers": [{
            "offerId": "wo_1",
            "status": "PENDING",
            "proName": "Kai",
            "proHref": "/professionals/pro_9",
            "avatarUrl": null,
            "serviceLabel": "Men’s Cut",
            "startAt": "2026-07-14T20:00:00.000Z",
            "endAt": "2026-07-14T20:45:00.000Z",
            "timeZone": "America/Los_Angeles",
            "locationType": "SALON",
            "expiresAt": null
          }]
        }
        """
        reset(Data(json.utf8))
        let bookings = BookingsService(api: await makeAPI())

        let offers = try await bookings.waitlistOffers()

        #expect(OffersURLProtocol.capturedPath == "/api/v1/client/waitlist-offers")
        #expect(OffersURLProtocol.capturedMethod == "GET")
        let only = try #require(offers.first)
        #expect(only.offerId == "wo_1")
        #expect(only.serviceLabel == "Men’s Cut")
    }

    // MARK: - respondToWaitlistOffer CONFIRM (books, returns the booking)

    @Test func respondConfirmPostsActionWithIdempotencyKeyAndReturnsBooking() async throws {
        reset(Data("""
        {"ok":true,"booking":{"id":"bkg_5","status":"ACCEPTED","scheduledFor":"2026-07-14T20:00:00.000Z"}}
        """.utf8))
        let bookings = BookingsService(api: await makeAPI())

        let booking = try await bookings.respondToWaitlistOffer(offerId: "wo_1", confirm: true)

        #expect(OffersURLProtocol.capturedPath == "/api/v1/client/waitlist-offers/wo_1")
        #expect(OffersURLProtocol.capturedMethod == "POST")
        #expect((OffersURLProtocol.capturedIdempotencyKey ?? "").isEmpty == false)

        let body = try #require(OffersURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["action"] as? String == "CONFIRM")

        #expect(booking?.id == "bkg_5")
        #expect(booking?.status == "ACCEPTED")
    }

    // MARK: - respondToWaitlistOffer DECLINE (no booking)

    @Test func respondDeclinePostsDeclineAndReturnsNil() async throws {
        reset(Data("{\"ok\":true}".utf8))
        let bookings = BookingsService(api: await makeAPI())

        let booking = try await bookings.respondToWaitlistOffer(offerId: "wo_1", confirm: false)

        #expect(OffersURLProtocol.capturedMethod == "POST")
        let body = try #require(OffersURLProtocol.capturedBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["action"] as? String == "DECLINE")
        #expect(booking == nil)
    }

    // MARK: - countdown / expiry derivations (pure)

    @Test func countdownAndExpiryDerivations() throws {
        let now = try #require(ProCalendarGrid.parseISO("2026-07-11T18:00:00.000Z"))

        // 30 minutes left → not expired, not urgent.
        let far = decodeOffer(expiresAt: "2026-07-11T18:30:00.000Z", expired: false)
        #expect(far.remaining(now: now) == 1800)
        #expect(!far.isExpired(now: now))
        #expect(!far.isUrgent(now: now))

        // 2 minutes left → urgent, not expired.
        let soon = decodeOffer(expiresAt: "2026-07-11T18:02:00.000Z", expired: false)
        #expect(soon.isUrgent(now: now))
        #expect(!soon.isExpired(now: now))

        // Timer already run out → expired (clamped remaining is 0).
        let past = decodeOffer(expiresAt: "2026-07-11T17:59:00.000Z", expired: false)
        #expect(past.remaining(now: now) == 0)
        #expect(past.isExpired(now: now))

        // Server-flagged expired even with a future timer / no timer.
        let flagged = decodeOffer(expiresAt: nil, expired: true)
        #expect(flagged.isExpired(now: now))
        #expect(flagged.remaining(now: now) == nil)

        // Countdown formatting mirrors the web formatCountdown.
        #expect(ClientPriorityOffer.countdownLabel(65) == "1:05")
        #expect(ClientPriorityOffer.countdownLabel(600) == "10:00")
        #expect(ClientPriorityOffer.countdownLabel(0) == "0:00")
        #expect(ClientPriorityOffer.countdownLabel(-5) == "0:00")
    }

    private func decodeOffer(expiresAt: String?, expired: Bool) -> ClientPriorityOffer {
        let expiresField = expiresAt.map { "\"\($0)\"" } ?? "null"
        let json = """
        {
          "recipientId": "r", "status": "PRIORITY_OFFERED",
          "expiresAt": \(expiresField), "expired": \(expired),
          "proName": "P", "proHref": null, "professionalId": "pro",
          "avatarUrl": null, "serviceLabel": "S", "serviceId": "svc", "offeringId": "off",
          "startAt": "2026-07-11T18:00:00.000Z", "endAt": null,
          "timeZone": "UTC", "locationType": "SALON", "note": null,
          "incentiveLabel": null, "claimHref": null
        }
        """
        // Force-try: the literal above is always valid.
        return try! JSONDecoder().decode(ClientPriorityOffer.self, from: Data(json.utf8))
    }
}
