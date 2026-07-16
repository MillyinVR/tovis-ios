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

/// Shape of a failed JSON response: `{ ok: false, error, code?, ... }`
/// (`jsonFail` in app/api/_utils/responses.ts). Extra fields some endpoints
/// attach are decoded here when a caller needs them — surfaced via
/// `APIError.serverDetails`. Today:
///
///  - `maskedDestination` (top level) — the self-serve-claim 409's "we sent a
///    link to t***@x.com" hint.
///  - `details.retryAfterSeconds` — how long a 429 wants us to wait.
struct APIErrorBody: Decodable {
    let error: String?
    let code: String?
    let maskedDestination: String?
    let details: Details?

    private enum CodingKeys: String, CodingKey {
        case error, code, maskedDestination, details
    }

    /// Hand-written so an unexpected `details` can't sink the whole body. A
    /// synthesized `Decodable` propagates a nested type mismatch to the parent,
    /// and `APIClient` decodes this with `try?` — so one odd `details` would drop
    /// `error` and `code` too, and a rate-limited user would get "Something went
    /// wrong" instead of the server's actual message. The optional hint degrades;
    /// the copy that has to reach the user does not.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        code = try? container.decodeIfPresent(String.self, forKey: .code)
        maskedDestination = try? container.decodeIfPresent(String.self, forKey: .maskedDestination)
        details = try? container.decodeIfPresent(Details.self, forKey: .details)
    }

    /// The `details` object a rate-limited (429) response carries. Built by
    /// `buildRateLimitResponse` (app/api/_utils/rateLimit.ts), which nests the
    /// whole decision — bucket/limit/remaining/reset/retryAfterSeconds/… — under
    /// this one key. We only model the field we act on.
    ///
    /// ⚠️ `retryAfterSeconds` is NESTED, never top level. Web read it at the top
    /// level for the life of the feature and its countdown silently never fired
    /// (fixed in tovis-app "read the resend cooldown from where the API actually
    /// sends it"). Decoded leniently as string-or-number: the wire sends a JSON
    /// number, but the equivalent `Retry-After` HTTP header is a string, and the
    /// precedent for tolerating both is `ProReferralRewardSettings.decodeMoney`.
    struct Details: Decodable {
        let retryAfterSeconds: Int?

        private enum CodingKeys: String, CodingKey {
            case retryAfterSeconds
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            let number: Double? =
                (try? container.decodeIfPresent(Double.self, forKey: .retryAfterSeconds))
                    ?? (try? container.decodeIfPresent(String.self, forKey: .retryAfterSeconds))
                        .flatMap { $0 }
                        .flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }

            guard let number, number.isFinite else {
                retryAfterSeconds = nil
                return
            }
            retryAfterSeconds = max(0, Int(number.rounded(.up)))
        }
    }
}