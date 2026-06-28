import Foundation

// Request + response models for the auth and device endpoints.
// These mirror the backend wire DTOs in lib/dto/auth.ts and lib/dto/deviceToken.ts.

/// POST /api/v1/auth/login — request body.
/// `deviceId` is the stable per-install id; sending it lets the session be
/// revoked per-device. Send the SAME id to POST /api/v1/devices.
struct LoginRequest: Encodable, Sendable {
    let email: String
    let password: String
    let deviceId: String?
}

/// POST /api/v1/auth/login — response (`AuthLoginResponseDTO`).
public struct LoginResponse: Codable, Sendable {
    public let user: AuthUser
    public let token: String
    public let nextUrl: String?
    public let isPhoneVerified: Bool
    public let isEmailVerified: Bool
    public let isFullyVerified: Bool
}

/// POST /api/v1/auth/apple — request body. `identityToken` is the JWT from
/// ASAuthorization; name is only present on the user's first authorization.
struct AppleLoginRequest: Encodable, Sendable {
    let identityToken: String
    let deviceId: String?
    let firstName: String?
    let lastName: String?
}

/// POST /api/v1/auth/phone-login/send — request body.
struct PhoneLoginSendRequest: Encodable, Sendable {
    let phone: String
}

/// POST /api/v1/auth/phone-login/send — response (always generic / enumeration-safe).
public struct PhoneLoginSendResponse: Codable, Sendable {
    public let message: String
}

/// POST /api/v1/auth/phone-login/verify — request body.
struct PhoneLoginVerifyRequest: Encodable, Sendable {
    let phone: String
    let code: String
    let deviceId: String?
}

/// POST /api/v1/auth/refresh — response (`AuthRefreshResponseDTO`).
public struct RefreshResponse: Codable, Sendable {
    public let token: String
}

// MARK: - Account phone verification (post-signup, e.g. after Sign in with Apple)
// These act on the authenticated (verification) session — distinct from the
// passwordless phone-LOGIN flow above.

/// POST /api/v1/auth/phone/correct — set the account phone + send an OTP.
struct PhoneCorrectRequest: Encodable, Sendable {
    let phone: String
}

/// POST /api/v1/auth/phone/verify — request body.
struct PhoneVerifyCodeRequest: Encodable, Sendable {
    let code: String
}

/// POST /api/v1/auth/phone/verify — response (`AuthPhoneVerifyResponseDTO`).
/// `token` is non-nil once the session is fully verified (a new ACTIVE token).
public struct PhoneVerifyResponse: Decodable, Sendable {
    public let isPhoneVerified: Bool
    public let isEmailVerified: Bool
    public let isFullyVerified: Bool
    public let requiresEmailVerification: Bool
    public let token: String?
}

/// Push platform — matches the backend `DevicePlatform` enum.
public enum DevicePlatform: String, Codable, Sendable {
    case ios = "IOS"
    case android = "ANDROID"
}

/// POST /api/v1/devices — request body.
struct DeviceRegisterRequest: Encodable, Sendable {
    let platform: DevicePlatform
    let token: String
    let deviceId: String
}

/// A registered device row (`DeviceTokenDTO`). The raw push `token` is
/// intentionally never echoed back by the server.
public struct DeviceTokenDTO: Codable, Sendable, Identifiable {
    public let id: String
    public let platform: String
    public let deviceId: String?
    public let isActive: Bool
    public let lastSeenAt: String?
    public let createdAt: String
}