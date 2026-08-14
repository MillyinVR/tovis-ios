import Foundation
import Testing

@testable import TovisKit

// Tori, 2026-08-14: "when a client chooses rebook now it should open to the time
// frame the pro gave them so they can just choose a date and time from there.
// not having to look for the date."
//
// Two halves, and only the second one is visible on screen: the anchor has to be
// COMPUTED right (this file), and it has to reach the REQUEST
// (`RebookStartDateWireTests`). Native had neither — `beginRebook` presented the
// booking flow with no date at all, under a comment claiming it opened "in the
// pro's suggested window".

private final class RebookWireURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var capturedURL: URL?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedURL = request.url
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct RebookWindowAnchorTests {
    /// 2026-08-14 12:00 UTC — 08:00 in New York, so "today" is unambiguously the
    /// 14th in that zone.
    private let now = Date(timeIntervalSince1970: 1_786_795_200)
    private let ny = "America/New_York"

    @Test("a future window opens the picker on its first day")
    func anchorsToWindowStart() {
        #expect(
            RebookWindowAnchor.openingDay(
                windowStartISO: "2026-08-25T14:00:00.000Z",
                timeZone: ny,
                now: now
            ) == "2026-08-25"
        )
    }

    @Test("the day is resolved in the APPOINTMENT's zone, not UTC")
    func resolvesTheDayInTheAppointmentZone() {
        // 03:30 UTC on the 26th is still 23:30 on the 25th in New York. The
        // scroller's day keys are location-local, so a UTC read would open the
        // picker one day past the window the card just promised.
        #expect(
            RebookWindowAnchor.openingDay(
                windowStartISO: "2026-08-26T03:30:00.000Z",
                timeZone: ny,
                now: now
            ) == "2026-08-25"
        )
    }

    @Test("a window that already started is NOT anchored — the route refuses a past date")
    func refusesAPastWindow() {
        #expect(
            RebookWindowAnchor.openingDay(
                windowStartISO: "2026-08-01T14:00:00.000Z",
                timeZone: ny,
                now: now
            ) == nil
        )
    }

    @Test("today is not anchored either — it is what the picker does anyway")
    func doesNotAnchorToToday() {
        #expect(
            RebookWindowAnchor.openingDay(
                windowStartISO: "2026-08-14T18:00:00.000Z",
                timeZone: ny,
                now: now
            ) == nil
        )
    }

    @Test("no window, an unparseable instant or an unknown zone all mean no anchor")
    func nilForMissingOrUnusableInput() {
        #expect(RebookWindowAnchor.openingDay(windowStartISO: nil, timeZone: ny, now: now) == nil)
        #expect(RebookWindowAnchor.openingDay(windowStartISO: "", timeZone: ny, now: now) == nil)
        #expect(
            RebookWindowAnchor.openingDay(
                windowStartISO: "not-a-date", timeZone: ny, now: now) == nil
        )
        #expect(
            RebookWindowAnchor.openingDay(
                windowStartISO: "2026-08-25T14:00:00.000Z", timeZone: nil, now: now) == nil
        )
        #expect(
            RebookWindowAnchor.openingDay(
                windowStartISO: "2026-08-25T14:00:00.000Z",
                timeZone: "Mars/Olympus_Mons",
                now: now
            ) == nil
        )
    }
}

@Suite(.serialized)
struct RebookStartDateWireTests {
    private func makeService() async -> BookingService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RebookWireURLProtocol.self]
        let tokenStore = TokenStore(service: "me.tovis.app.session.rebookwire.tests")
        await tokenStore.save("session.token.value")
        return BookingService(api: APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: URLSession(configuration: configuration),
            tokenStore: tokenStore
        ))
    }

    private func capturedQuery() throws -> [String: String] {
        let url = try #require(RebookWireURLProtocol.capturedURL)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test("bootstrap moves its whole window when the caller anchors it")
    func bootstrapSendsStartDate() async throws {
        RebookWireURLProtocol.body = try fixture("availabilityBootstrap")
        _ = try await makeService().bootstrap(
            professionalId: "pro_1", serviceId: "svc_1", offeringId: "off_1",
            locationType: "SALON", clientAddressId: nil, mediaId: nil,
            days: 7, startDate: "2026-08-25"
        )

        let query = try capturedQuery()
        #expect(query["startDate"] == "2026-08-25")
        // The window still spans a week — it just starts somewhere else.
        #expect(query["days"] == "7")
    }

    @Test("an ordinary booking sends no startDate at all, not an empty one")
    func bootstrapOmitsStartDateByDefault() async throws {
        RebookWireURLProtocol.body = try fixture("availabilityBootstrap")
        _ = try await makeService().bootstrap(
            professionalId: "pro_1", serviceId: "svc_1", offeringId: "off_1"
        )

        #expect(try capturedQuery()["startDate"] == nil)
    }
}
