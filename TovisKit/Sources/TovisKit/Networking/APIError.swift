import Foundation

/// Errors surfaced by `APIClient`.
public enum APIError: Error, Sendable, Equatable {
    /// The response wasn't an HTTP response, or was otherwise malformed.
    case invalidResponse
    /// Non-2xx status. `message`/`code` come from the `{ ok:false, error, code }` body when present.
    case server(status: Int, message: String?, code: String?)
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
        case .unauthorized:
            return "Your session has expired. Please sign in again."
        case .decoding:
            return "We couldn't read the server response."
        case .transport:
            return "Can't reach the server. Check your connection."
        }
    }
}