import Foundation
import Testing
@testable import TovisKit

// `APIError.isRetryable` decides whether a caller holding the user's bytes
// should offer "try again" or "this will never work — here's your photo back".
//
// This exists because the session camera treated EVERY failure as retryable: a
// server refusal (a 4xx the server will repeat forever) queued behind the same
// "Retry N unsaved photos" button as a dropped connection. The button could not
// win, there was no other way out, and the bytes were swept on the next camera
// launch — so a refused AFTER photo was lost with no warning. The split below
// is what makes the two paths distinguishable, so the terminal one can offer a
// real escape instead of a button that re-fails.

@Suite struct APIErrorRetryTests {
    // MARK: - Retryable

    @Test func transportAndMalformedResponsesAreRetryable() {
        #expect(APIError.transport("offline").isRetryable)
        #expect(APIError.invalidResponse.isRetryable)
    }

    @Test func timeoutAndRateLimitAreRetryable() {
        #expect(APIError.server(status: 408, message: nil, code: nil).isRetryable)
        #expect(APIError.server(status: 429, message: nil, code: nil).isRetryable)
    }

    @Test func serverSideFailuresAreRetryable() {
        for status in [500, 502, 503, 504, 599] {
            #expect(
                APIError.server(status: status, message: nil, code: nil).isRetryable,
                "\(status) is transient and must stay retryable")
        }
    }

    // MARK: - Terminal

    @Test func clientRefusalsAreTerminal() {
        // The exact refusals the pro-booking-media upload path can return —
        // every one is a considered rejection of THESE bytes, so re-sending
        // them reproduces it. See app/api/v1/pro/{uploads,bookings/[id]/media}.
        for status in [400, 403, 404, 409, 413, 415, 422] {
            #expect(
                !APIError.server(status: status, message: nil, code: nil).isRetryable,
                "\(status) is a refusal — retrying re-fails forever")
        }
    }

    @Test func unauthorizedIsTerminalBecauseRefreshAlreadyFailed() {
        // `.unauthorized` is only raised AFTER a token refresh failed, so an
        // immediate retry re-fails. Retrying would spin, not recover.
        #expect(!APIError.unauthorized.isRetryable)
    }

    @Test func decodingIsTerminalToAvoidDuplicateAssets() {
        // Decoding failures follow a 2xx: the write landed and only the body
        // failed to parse. A retry mints a fresh upload session and therefore a
        // SECOND asset — a duplicate in the client's chart is worse than asking
        // the caller to keep its local copy.
        #expect(!APIError.decoding("bad shape").isRetryable)
    }

    // MARK: - Both server cases agree

    @Test func serverDetailsClassifiesIdenticallyToServer() {
        // `.serverDetails` is `.server` plus opted-in body fields; a caller that
        // opts into details must not get a different retry verdict for it.
        for status in [400, 408, 409, 429, 500, 503] {
            let plain = APIError.server(status: status, message: nil, code: nil)
            let detailed = APIError.serverDetails(
                status: status, message: nil, code: nil,
                details: ServerErrorDetails(retryAfterSeconds: 30))
            #expect(
                plain.isRetryable == detailed.isRetryable,
                "\(status) must classify the same with and without details")
        }
    }
}
