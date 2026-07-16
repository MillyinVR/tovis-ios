import Foundation

/// Extra fields lifted off a failed response body for the callers that opt in
/// via `captureErrorDetails`. Grouped in a struct rather than added as more
/// positional payload on `APIError.serverDetails`, so the next hint that needs
/// carrying doesn't grow a wider tuple at every call site.
public struct ServerErrorDetails: Sendable, Equatable {
    /// The self-serve-claim 409's masked hint ("we sent a link to t***@x.com").
    /// Read from the TOP level of the body.
    public let maskedDestination: String?
    /// How long a rate-limited (429) response wants us to wait, from
    /// `details.retryAfterSeconds`. Drives the OTP resend countdown — see
    /// `OTPResendCooldown`.
    public let retryAfterSeconds: Int?

    public init(maskedDestination: String? = nil, retryAfterSeconds: Int? = nil) {
        self.maskedDestination = maskedDestination
        self.retryAfterSeconds = retryAfterSeconds
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
}