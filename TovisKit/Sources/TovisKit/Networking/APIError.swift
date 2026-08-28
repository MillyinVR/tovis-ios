import Foundation

/// Extra fields lifted off a failed response body for the callers that opt in
/// via `captureErrorDetails`. Grouped in a struct rather than added as more
/// positional payload on `APIError.serverDetails`, so the next hint that needs
/// carrying doesn't grow a wider tuple at every call site.
public struct ServerErrorDetails: Sendable, Equatable {
    /// The self-serve-claim 409's masked hint ("we sent a link to t***@x.com").
    /// Read from the TOP level of the body.
    public let maskedDestination: String?
    /// Whether the self-serve-claim 409 actually queued a claim link. Nil on a
    /// server that predates the field; false means NOTHING was sent, so the
    /// screen must not tell the client to go check their messages.
    public let claimLinkSent: Bool?
    /// How long a rate-limited (429) response wants us to wait, from
    /// `details.retryAfterSeconds`. Drives the OTP resend countdown — see
    /// `OTPResendCooldown`.
    public let retryAfterSeconds: Int?
    /// The pro's live-hold decision, on a HOLD_OVERLAP_NEEDS_CONFIRMATION 409.
    /// Read from the TOP level of the body. See `HoldOverlapDecision.swift`.
    public let heldSlot: HeldSlotDecision?

    public init(
        maskedDestination: String? = nil,
        claimLinkSent: Bool? = nil,
        retryAfterSeconds: Int? = nil,
        heldSlot: HeldSlotDecision? = nil
    ) {
        self.maskedDestination = maskedDestination
        self.claimLinkSent = claimLinkSent
        self.retryAfterSeconds = retryAfterSeconds
        self.heldSlot = heldSlot
    }
}

/// Errors surfaced by `APIClient`.
public enum APIError: Error, Sendable, Equatable {
    /// The response wasn't an HTTP response, or was otherwise malformed.
    case invalidResponse
    /// Non-2xx status. `message`/`code` come from the `{ ok:false, error, code }` body when present.
    case server(status: Int, message: String?, code: String?)
    /// Non-2xx status like `.server`, but additionally carrying extra body fields
    /// a specific caller opted to decode (`captureErrorDetails: true`) — see
    /// `ServerErrorDetails`. Kept as its own case so every existing
    /// `case .server` matcher stays untouched; only opted-in calls ever see it.
    case serverDetails(status: Int, message: String?, code: String?, details: ServerErrorDetails)
    /// 401 that we could not recover from (refresh failed / no session).
    case unauthorized
    /// JSON decoding of a success body failed.
    case decoding(String)
    /// URLSession transport failure (offline, timeout, TLS, …).
    case transport(String)

    public var userMessage: String {
        switch self {
        case .invalidResponse:
            return "Something went wrong. Please try again."
        case let .server(_, message, _):
            return message ?? "Something went wrong. Please try again."
        case let .serverDetails(_, message, _, _):
            return message ?? "Something went wrong. Please try again."
        case .unauthorized:
            return "Your session has expired. Please sign in again."
        case .decoding:
            return "We couldn't read the server response."
        case .transport:
            return "Can't reach the server. Check your connection."
        }
    }

    /// Whether re-sending the SAME request could plausibly succeed later.
    ///
    /// Callers that hold bytes on the user's behalf (the session camera's failed
    /// -upload queue) need this to tell "waiting on signal" from "the server
    /// refused these bytes". Offering a Retry button for a refusal the server
    /// will repeat forever is what stranded photos with no way out — the retry
    /// can never win, and the work is silently lost on exit.
    ///
    /// Retryable: transport failures, a malformed/absent HTTP response, request
    /// timeout (408), rate limiting (429), and any 5xx — all transient by
    /// definition.
    ///
    /// Terminal: every other 4xx (400/403/404/409/413/415/422 …). The request
    /// was understood and rejected; the same bytes will be rejected again.
    /// `.unauthorized` is terminal too — it is only raised once a token refresh
    /// has ALREADY failed, so an immediate retry re-fails.
    ///
    /// `.decoding` is deliberately terminal even though it follows a 2xx: the
    /// write almost certainly landed and only the response body failed to parse.
    /// Retrying would mint a second upload session and therefore a DUPLICATE
    /// asset, which is worse than telling the caller to keep its local copy.
    public var isRetryable: Bool {
        switch self {
        case .transport, .invalidResponse:
            return true
        case let .server(status, _, _), let .serverDetails(status, _, _, _):
            return status == 408 || status == 429 || (500...599).contains(status)
        case .unauthorized, .decoding:
            return false
        }
    }
}