import Foundation
import Testing
@testable import TovisKit

// Presence on the opening claim path — GET /api/v1/presence/signals and
// POST /api/v1/client/presence/heartbeat.
//
// Every envelope below is a VERBATIM capture from the running routes (local
// server, two separately-minted CLIENT jwts, real seeded opening
// cmrr3luyt0004po7o99k7gu7m, 2026-07-19).
//
// ⚠️ These tests exist in the shadow of #677/#178, where FIVE green tests
// stubbed both halves of a false premise (an id-only resolve AND an inbox that
// always contained the thread) and stayed green straight through an outage.
// The guard against repeating that here is that the stub below can express
// every answer the SERVER actually gives, including the ones that must render
// NOTHING:
//   • watching:0 — the unknown / expired / never-heartbeated opening
//   • watching:1 — the viewer alone (below threshold; the whole point)
//   • watching:null — Redis down, i.e. UNKNOWN, which is not zero
//   • waitlisted:0 — below its own threshold
// A test that could only ever produce watching:5 would prove nothing.
//
// Also pinned from that drive:
//   • the read is PUBLIC (200 with no Authorization header) and NEVER 404s —
//     an invented resourceId and an unknown professionalId both answer
//     200 {"watching":0,"waitlisted":0}.
//   • the heartbeat genuinely READS its body: bad resourceType, {}, no body and
//     malformed JSON are each 400. A clientId in the body is ignored.
//   • the heartbeat needs a FULLY VERIFIED client, not just a signed-in one —
//     an unverified account is 403 VERIFICATION_REQUIRED (found the hard way
//     while seeding a second watcher).
//   • no rate limit (10 rapid POSTs → 200×10) and no idempotency wrapper, but
//     it is naturally idempotent: ZADD keyed on the client id, so ten
//     heartbeats from one client still read back watching:1.

/// Records the outgoing request and serves a canned envelope.
final class PresenceURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedPath: String?
    nonisolated(unsafe) static var capturedQuery: String?
    nonisolated(unsafe) static var capturedMethod: String?
    nonisolated(unsafe) static var capturedBody: Data?
    nonisolated(unsafe) static var capturedHeaders: [String: String] = [:]
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var responseBody = Data("{\"ok\":true}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedPath = request.url?.path
        Self.capturedQuery = request.url?.query
        Self.capturedMethod = request.httpMethod
        Self.capturedBody = request.httpBody ?? request.presenceBodyStreamData()
        Self.capturedHeaders = request.allHTTPHeaderFields ?? [:]
        Self.requestCount += 1

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: Self.status, httpVersion: nil,
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func presenceBodyStreamData() -> Data? {
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

// MARK: - Verbatim captures

/// Two real clients heartbeating + two ACTIVE waitlist rows. The threshold case.
private let liveBothSignals = """
{"ok":true,"signals":{"watching":2,"waitlisted":2}}
"""
/// One client — the viewer alone. `watching` MUST NOT render.
private let liveViewerAloneSignals = """
{"ok":true,"signals":{"watching":1,"waitlisted":2}}
"""
/// An invented resourceId, and separately an unknown professionalId, both gave
/// exactly this. Note it is a 200, not a 404.
private let liveUnknownResourceSignals = """
{"ok":true,"signals":{"watching":0,"waitlisted":0}}
"""
/// Redis unavailable. Shape proven by tovis-app's own unit test of the real
/// `getPresenceSignals` (lib/presence/presenceSignals.test.ts:166-174, green)
/// and by the route's declared `watching: number | null`; NOT driven over HTTP
/// here, because prod/local Upstash is configured and could not be taken down
/// from a test.
private let liveRedisDownSignals = """
{"ok":true,"signals":{"watching":null,"waitlisted":2}}
"""
private let liveHeartbeatRecorded = """
{"ok":true,"recorded":true}
"""
/// 403 for a signed-in but not fully verified client.
private let liveVerificationRequired = """
{"ok":false,"error":"Account verification is required.","code":"VERIFICATION_REQUIRED"}
"""

@Suite(.serialized) struct PresenceServiceTests {
    private func makeService() async -> PresenceService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PresenceURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.presence.tests")
        await tokenStore.save("session.token.value")
        guard let baseURL = URL(string: "https://test.local/api/v1") else {
            fatalError("static test URL must parse")
        }
        let api = APIClient(
            config: TovisConfig(baseURL: baseURL),
            session: session,
            tokenStore: tokenStore
        )
        return PresenceService(api: api)
    }

    private func reset(_ body: String = liveBothSignals, status: Int = 200) {
        PresenceURLProtocol.capturedPath = nil
        PresenceURLProtocol.capturedQuery = nil
        PresenceURLProtocol.capturedMethod = nil
        PresenceURLProtocol.capturedBody = nil
        PresenceURLProtocol.capturedHeaders = [:]
        PresenceURLProtocol.requestCount = 0
        PresenceURLProtocol.status = status
        PresenceURLProtocol.responseBody = Data(body.utf8)
    }

    // MARK: - Decoding the real envelopes

    @Test func decodesTheLiveSignalsEnvelope() async throws {
        reset(liveBothSignals)

        let signals = try await makeService().signals(
            resourceType: .opening,
            resourceId: "cmrr3luyt0004po7o99k7gu7m",
            professionalId: "cmrbry44b0003po0d5f1fcs2u",
            serviceId: "cmrbry482000xpo0di0hbjtni"
        )

        #expect(PresenceURLProtocol.capturedPath == "/api/v1/presence/signals")
        #expect(PresenceURLProtocol.capturedMethod == "GET")
        #expect(signals.watching == 2)
        #expect(signals.waitlisted == 2)
    }

    /// The UNKNOWN case: null is not zero. Collapsing it would let "we can't
    /// tell" render as "nobody is here".
    @Test func redisDownDecodesToNilWatchingNotZero() async throws {
        reset(liveRedisDownSignals)

        let signals = try await makeService().signals(
            resourceType: .opening, resourceId: "op-1", professionalId: "pro-1"
        )

        #expect(signals.watching == nil)
        #expect(signals.waitlisted == 2)
    }

    @Test func missingWaitlistedKeyDecodesToZero() async throws {
        reset("{\"ok\":true,\"signals\":{\"watching\":3}}")

        let signals = try await makeService().signals(
            resourceType: .opening, resourceId: "op-1", professionalId: "pro-1"
        )

        #expect(signals.watching == 3)
        #expect(signals.waitlisted == 0)
    }

    @Test func heartbeatDecodesRecordedFlag() async throws {
        reset(liveHeartbeatRecorded)

        let recorded = try await makeService().heartbeat(
            resourceType: .opening, resourceId: "cmrr3luyt0004po7o99k7gu7m"
        )

        #expect(recorded)
        #expect(PresenceURLProtocol.capturedPath == "/api/v1/client/presence/heartbeat")
        #expect(PresenceURLProtocol.capturedMethod == "POST")
    }

    @Test func heartbeatWithoutRecordedFlagDefaultsToFalse() async throws {
        reset("{\"ok\":true}")

        let recorded = try await makeService().heartbeat(
            resourceType: .opening, resourceId: "op-1"
        )

        #expect(recorded == false)
    }

    // MARK: - What goes on the wire

    @Test func sendsEveryQueryParamTheRouteRequires() async throws {
        reset()

        _ = try await makeService().signals(
            resourceType: .opening,
            resourceId: "op-1",
            professionalId: "pro-1",
            serviceId: "svc-1"
        )

        let query = try #require(PresenceURLProtocol.capturedQuery)
        #expect(query.contains("resourceType=opening"))
        #expect(query.contains("resourceId=op-1"))
        #expect(query.contains("professionalId=pro-1"))
        #expect(query.contains("serviceId=svc-1"))
    }

    /// Omitted, not sent blank — a blank `serviceId` would widen the waitlist
    /// count to the whole pro without saying so. (The route treats "" as absent
    /// anyway, but sending it hides the intent.)
    @Test func omitsServiceIdEntirelyWhenNil() async throws {
        reset()

        _ = try await makeService().signals(
            resourceType: .opening, resourceId: "op-1", professionalId: "pro-1"
        )

        let query = try #require(PresenceURLProtocol.capturedQuery)
        #expect(!query.contains("serviceId"))
    }

    @Test func heartbeatBodyIsCanonicalAndCarriesNoClientId() async throws {
        reset(liveHeartbeatRecorded)

        _ = try await makeService().heartbeat(
            resourceType: .opening, resourceId: "op-1"
        )

        let data = try #require(PresenceURLProtocol.capturedBody)
        let raw = String(decoding: data, as: UTF8.self)
        // JSONEncoder.canonical sorts keys: resourceId before resourceType.
        #expect(raw == "{\"resourceId\":\"op-1\",\"resourceType\":\"opening\"}")
        // The server takes the client from the session and ignores a body one.
        #expect(!raw.contains("clientId"))
    }

    /// The route has no idempotency wrapper (driven: the same key twice with
    /// different bodies processed both), and a ZADD needs none. Sending one
    /// would imply a replay contract the route does not have.
    @Test func heartbeatSendsNoIdempotencyKey() async throws {
        reset(liveHeartbeatRecorded)

        _ = try await makeService().heartbeat(resourceType: .opening, resourceId: "op-1")

        let headers = PresenceURLProtocol.capturedHeaders
        #expect(headers["idempotency-key"] == nil)
        #expect(headers["Idempotency-Key"] == nil)
    }

    /// The service must not swallow a refusal — the CALLER decides that
    /// presence failures are silent, and it can only decide that if it is told.
    @Test func verificationRequiredSurfacesAsAnError() async throws {
        reset(liveVerificationRequired, status: 403)

        await #expect(throws: (any Error).self) {
            _ = try await self.makeService().heartbeat(
                resourceType: .opening, resourceId: "op-1"
            )
        }
    }

    // MARK: - The honest thresholds (the feature)

    @Test func showsBothCountsOnceEachClearsItsThreshold() {
        let display = PresenceDisplay(signals: PresenceSignals(watching: 2, waitlisted: 2))

        #expect(display.watching == 2)
        #expect(display.waitlisted == 2)
        #expect(!display.isEmpty)
    }

    /// The capture that defines the feature: the viewer counts themselves, so a
    /// lone viewer must never be told "1 watching now".
    @Test func hidesWatchingWhenItIsOnlyTheViewer() {
        let display = PresenceDisplay(signals: PresenceSignals(watching: 1, waitlisted: 2))

        #expect(display.watching == nil)
        #expect(display.waitlisted == 2)
    }

    @Test func unknownOpeningRendersNothingAtAll() {
        // The verbatim answer for an invented / expired opening id.
        let display = PresenceDisplay(signals: PresenceSignals(watching: 0, waitlisted: 0))

        #expect(display.isEmpty)
    }

    @Test func redisDownHidesWatchingButKeepsWaitlist() {
        let display = PresenceDisplay(signals: PresenceSignals(watching: nil, waitlisted: 3))

        #expect(display.watching == nil)
        #expect(display.waitlisted == 3)
    }

    @Test func noSignalsYetIsEmpty() {
        #expect(PresenceDisplay(signals: nil).isEmpty)
        #expect(PresenceDisplay.empty.isEmpty)
    }

    @Test func hidesWaitlistWhenNobodyIsWaiting() {
        let display = PresenceDisplay(signals: PresenceSignals(watching: 4, waitlisted: 0))

        #expect(display.watching == 4)
        #expect(display.waitlisted == nil)
    }

    @Test func matchesWebsThresholdConstants() {
        #expect(PresenceThreshold.minWatching == 2)
        #expect(PresenceThreshold.minWaitlisted == 1)
    }

    // MARK: - Poll cadence

    @Test func pollsActivelyUntilTheCountsSettle() {
        var schedule = PresencePollSchedule()
        #expect(schedule.nextInterval == .seconds(15))

        schedule.record(unchanged: true)
        #expect(schedule.nextInterval == .seconds(15))
        schedule.record(unchanged: true)
        #expect(schedule.nextInterval == .seconds(15))
        schedule.record(unchanged: true)
        #expect(schedule.nextInterval == .seconds(30))
    }

    @Test func anyChangeReturnsToTheActiveCadence() {
        var schedule = PresencePollSchedule()
        for _ in 0..<4 { schedule.record(unchanged: true) }
        #expect(schedule.nextInterval == .seconds(30))

        schedule.record(unchanged: false)
        #expect(schedule.nextInterval == .seconds(15))
        #expect(schedule.stableRounds == 0)
    }

    @Test func heartbeatIntervalStaysInsideTheServersWatchingWindow() {
        // The server prunes at 60s (WATCHING_WINDOW_SECONDS) and expires the key
        // at 90s, so a 30s heartbeat can never let a present viewer lapse.
        #expect(PresenceHeartbeat.interval == .seconds(30))
        #expect(PresenceHeartbeat.interval < .seconds(60))
    }
}
