import Foundation
import Testing
@testable import TovisKit

// Covers the SMS resend cooldown: the pure date math, and the plumbing that
// carries a 429's `retryAfterSeconds` from the wire to the model.
//
// The shape assertions matter more than they look. `retryAfterSeconds` is nested
// under `details` — `buildRateLimitResponse` (app/api/_utils/rateLimit.ts) puts
// the whole rate-limit decision there and `jsonFail` spreads it as-is. Web read
// it at the TOP level for the life of the feature, its unit tests mocked a
// top-level field to match, and so reader and mocks agreed with each other while
// disagreeing with the server: the countdown never fired once in production
// (fixed in tovis-app, "read the resend cooldown from where the API actually
// sends it"). The body below is a verbatim capture of a real 429 rather than a
// hand-written guess, precisely so this client can't repeat that.

@Suite struct OTPResendCooldownFormatTests {
    @Test func formatsSecondsAsMinutesAndPaddedSeconds() {
        #expect(OTPResendCooldown.format(seconds: 0) == "0:00")
        #expect(OTPResendCooldown.format(seconds: 5) == "0:05")
        #expect(OTPResendCooldown.format(seconds: 59) == "0:59")
        #expect(OTPResendCooldown.format(seconds: 60) == "1:00")
        #expect(OTPResendCooldown.format(seconds: 75) == "1:15")
        #expect(OTPResendCooldown.format(seconds: 600) == "10:00")
        // The auth:email:send bucket really does hand back ~15 minutes.
        #expect(OTPResendCooldown.format(seconds: 899) == "14:59")
    }

    @Test func clampsNegativesToZero() {
        #expect(OTPResendCooldown.format(seconds: -10) == "0:00")
    }

    /// Matches web's RESEND_COOLDOWN_SECONDS.
    @Test func defaultIsSixtySeconds() {
        #expect(OTPResendCooldown.defaultSeconds == 60)
    }
}

@Suite struct OTPResendCooldownStateTests {
    private let start = Date(timeIntervalSince1970: 1_784_240_000)

    @Test func startsInactive() {
        let cooldown = OTPResendCooldown()
        #expect(cooldown.deadline == nil)
        #expect(!cooldown.isActive(now: start))
        #expect(cooldown.remainingSeconds(now: start) == 0)
        #expect(cooldown.remainingLabel(now: start) == nil)
    }

    @Test func countsDownFromTheDeadlineAsTheClockMoves() {
        var cooldown = OTPResendCooldown()
        cooldown.start(seconds: 60, now: start)

        #expect(cooldown.isActive(now: start))
        #expect(cooldown.remainingSeconds(now: start) == 60)
        #expect(cooldown.remainingLabel(now: start) == "1:00")
        #expect(cooldown.remainingLabel(now: start.addingTimeInterval(18)) == "0:42")
        #expect(cooldown.remainingLabel(now: start.addingTimeInterval(59)) == "0:01")
    }

    @Test func expiresExactlyAtTheDeadline() {
        var cooldown = OTPResendCooldown()
        cooldown.start(seconds: 60, now: start)

        #expect(!cooldown.isActive(now: start.addingTimeInterval(60)))
        #expect(cooldown.remainingSeconds(now: start.addingTimeInterval(60)) == 0)
        #expect(cooldown.remainingLabel(now: start.addingTimeInterval(60)) == nil)
    }

    /// The whole reason this is a deadline and not a ticking counter: a suspended
    /// app runs no timers, so time passing while backgrounded must still count.
    @Test func timePassesWhileNothingIsTicking() {
        var cooldown = OTPResendCooldown()
        cooldown.start(seconds: 899, now: start)

        // Backgrounded for 15 minutes; no tick ever ran.
        #expect(!cooldown.isActive(now: start.addingTimeInterval(900)))
    }

    /// A partial second still reads as ≥1, so the button never shows "0:00"
    /// while it's still disabled.
    @Test func roundsPartialSecondsUp() {
        var cooldown = OTPResendCooldown()
        cooldown.start(seconds: 60, now: start)

        #expect(cooldown.remainingSeconds(now: start.addingTimeInterval(59.5)) == 1)
        #expect(cooldown.remainingLabel(now: start.addingTimeInterval(59.5)) == "0:01")
    }

    @Test func neverShortensAnActiveCooldown() {
        var cooldown = OTPResendCooldown()
        // The server says wait 15 minutes…
        cooldown.start(seconds: 899, now: start)
        // …a later optimistic 60s send must not hand the button back early.
        cooldown.start(seconds: 60, now: start.addingTimeInterval(1))

        #expect(cooldown.remainingSeconds(now: start.addingTimeInterval(1)) == 898)
    }

    @Test func extendsToTheLongerDeadline() {
        var cooldown = OTPResendCooldown()
        cooldown.start(seconds: 60, now: start)
        cooldown.start(seconds: 899, now: start)

        #expect(cooldown.remainingSeconds(now: start) == 899)
    }

    @Test func ignoresNonPositiveDurations() {
        var cooldown = OTPResendCooldown()
        cooldown.start(seconds: 0, now: start)
        #expect(cooldown.deadline == nil)

        cooldown.start(seconds: -5, now: start)
        #expect(cooldown.deadline == nil)
    }

    @Test func resetClearsIt() {
        var cooldown = OTPResendCooldown()
        cooldown.start(seconds: 899, now: start)
        cooldown.reset()

        #expect(cooldown.deadline == nil)
        #expect(!cooldown.isActive(now: start))
    }
}

@Suite struct OTPRetryAfterExtractionTests {
    /// Verbatim body of a real 429 from POST /api/v1/auth/phone-login/send,
    /// captured by tripping the auth:email:send bucket against a dev server.
    private static let realRateLimitBody = """
    {"ok":false,"error":"Too many requests. Please slow down.","code":"RATE_LIMITED",
     "details":{"bucket":"auth:email:send","limit":5,"remaining":0,
     "reset":1784241270333,"retryAfterSeconds":899,"source":"redis",
     "reason":"rate_limited"}}
    """

    private func decodeBody(_ json: String) throws -> APIErrorBody {
        try JSONDecoder().decode(APIErrorBody.self, from: Data(json.utf8))
    }

    @Test func decodesTheHintFromARealRateLimitBody() throws {
        let body = try decodeBody(Self.realRateLimitBody)
        #expect(body.code == "RATE_LIMITED")
        #expect(body.details?.retryAfterSeconds == 899)
    }

    /// The bug web shipped: the field is never at the top level.
    @Test func ignoresATopLevelHint() throws {
        let body = try decodeBody(#"{"ok":false,"error":"nope","retryAfterSeconds":42}"#)
        #expect(body.details?.retryAfterSeconds == nil)
    }

    @Test func toleratesAMissingOrUnparseableHint() throws {
        #expect(try decodeBody(#"{"ok":false,"error":"x"}"#).details == nil)
        #expect(try decodeBody(#"{"ok":false,"details":{}}"#).details?.retryAfterSeconds == nil)
        #expect(try decodeBody(#"{"ok":false,"details":{"retryAfterSeconds":null}}"#)
            .details?.retryAfterSeconds == nil)
        #expect(try decodeBody(#"{"ok":false,"details":{"retryAfterSeconds":"abc"}}"#)
            .details?.retryAfterSeconds == nil)
    }

    /// An unexpected `details` shape must not fail the WHOLE body's decode — the
    /// message and code still have to reach the user.
    @Test func anUnexpectedDetailsShapeStillYieldsTheMessage() throws {
        let body = try decodeBody(#"{"ok":false,"error":"Too many requests.","code":"RATE_LIMITED","details":"nope"}"#)
        #expect(body.error == "Too many requests.")
        #expect(body.code == "RATE_LIMITED")
        #expect(body.details?.retryAfterSeconds == nil)
    }

    @Test func acceptsNumericStringsAndRoundsUp() throws {
        #expect(try decodeBody(#"{"details":{"retryAfterSeconds":"45"}}"#)
            .details?.retryAfterSeconds == 45)
        #expect(try decodeBody(#"{"details":{"retryAfterSeconds":45.9}}"#)
            .details?.retryAfterSeconds == 46)
        #expect(try decodeBody(#"{"details":{"retryAfterSeconds":-5}}"#)
            .details?.retryAfterSeconds == 0)
    }

    // MARK: - APIError → cooldown

    @Test func readsTheHintOffARateLimitedError() {
        let error = APIError.serverDetails(
            status: 429,
            message: "Too many requests. Please slow down.",
            code: "RATE_LIMITED",
            details: ServerErrorDetails(retryAfterSeconds: 899)
        )
        #expect(OTPResendCooldown.retryAfterSeconds(from: error) == 899)
    }

    /// A non-429 must not start a cooldown, even if it somehow carries details —
    /// only the rate limiter is telling us to wait.
    @Test func ignoresNon429Errors() {
        let claim = APIError.serverDetails(
            status: 409,
            message: "We found existing history.",
            code: "CLAIMABLE_HISTORY",
            details: ServerErrorDetails(maskedDestination: "t***@x.com")
        )
        #expect(OTPResendCooldown.retryAfterSeconds(from: claim) == nil)
        #expect(OTPResendCooldown.retryAfterSeconds(from: APIError.unauthorized) == nil)
        #expect(OTPResendCooldown.retryAfterSeconds(
            from: APIError.server(status: 429, message: "x", code: "RATE_LIMITED")
        ) == nil)
    }
}

/// Own statics, so this can't race the identically-shaped stub in
/// RegisterClientClaimableHistoryTests (Swift Testing runs suites in parallel).
final class RateLimitedURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseBody = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "Retry-After": "899"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Drives the throttled send calls through a real `APIClient`, so the
/// `captureErrorDetails` wiring is covered end-to-end rather than assumed: it has
/// to be requested per call AND forwarded (`requestVoid` silently dropped the
/// flag before this change, which would have stranded the hint on the floor with
/// every unit test still green).
@Suite(.serialized) struct OTPResendCooldownTransportTests {
    private static let realRateLimitBody = Data("""
    {"ok":false,"error":"Too many requests. Please slow down.","code":"RATE_LIMITED",
     "details":{"bucket":"auth:sms-phone-hour","limit":5,"remaining":0,
     "reset":1784241270333,"retryAfterSeconds":899,"source":"redis",
     "reason":"rate_limited"}}
    """.utf8)

    private func makeAuth() -> AuthService {
        RateLimitedURLProtocol.responseBody = Self.realRateLimitBody

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let tokenStore = TokenStore(service: "me.tovis.app.session.cooldown.tests")
        let api = APIClient(
            config: TovisConfig(baseURL: URL(string: "https://test.local/api/v1")!),
            session: session,
            tokenStore: tokenStore
        )
        return AuthService(api: api, tokenStore: tokenStore, appAttest: RecordingAttestProvider(returning: nil))
    }

    @Test func phoneLoginSendSurfacesTheCooldown() async {
        let auth = makeAuth()
        do {
            _ = try await auth.phoneLoginSend(phone: "+15551234567")
            Issue.record("expected a 429")
        } catch {
            #expect(OTPResendCooldown.retryAfterSeconds(from: error) == 899)
        }
    }

    /// requestVoid-based, and the call a user actually hammers.
    @Test func resendAccountPhoneCodeSurfacesTheCooldown() async {
        let auth = makeAuth()
        do {
            try await auth.resendAccountPhoneCode()
            Issue.record("expected a 429")
        } catch {
            #expect(OTPResendCooldown.retryAfterSeconds(from: error) == 899)
        }
    }

    @Test func setAccountPhoneAndSendCodeSurfacesTheCooldown() async {
        let auth = makeAuth()
        do {
            try await auth.setAccountPhoneAndSendCode(phone: "+15551234567")
            Issue.record("expected a 429")
        } catch {
            #expect(OTPResendCooldown.retryAfterSeconds(from: error) == 899)
        }
    }
}
