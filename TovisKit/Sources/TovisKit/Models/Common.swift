import Foundation

/// Backend roles. Kept as a `String`-backed value with an `unknown` fallback so
/// the app never fails to decode if the backend adds a role later.
public enum Role: String, Codable, Sendable {
    case client = "CLIENT"
    case pro = "PRO"
    case admin = "ADMIN"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Role(rawValue: raw) ?? .unknown
    }
}

/// Minimal user identity echoed by the auth endpoints
/// (matches `AuthUserDTO` in lib/dto/auth.ts).
public struct AuthUser: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let email: String
    public let role: Role
}

/// Shape of a failed JSON response: `{ ok: false, error, code? }`
/// (`jsonFail` in app/api/_utils/responses.ts).
struct APIErrorBody: Decodable {
    let error: String?
    let code: String?
}