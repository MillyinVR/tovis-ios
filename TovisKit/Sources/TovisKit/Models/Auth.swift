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

/// A client's ZIP resolved to the coordinates + IANA timezone the signup needs
/// for its `CLIENT_ZIP` `signupLocation` payload. Produced by
/// `PlacesService.resolveClientZip` (geocode + timezone), consumed by
/// `AuthService.registerClient`. Mirrors the web client signup's `ConfirmedZip`.
public struct ClientSignupLocation: Sendable, Equatable {
    public let postalCode: String
    public let city: String?
    public let state: String?
    public let countryCode: String?
    public let lat: Double
    public let lng: Double
    public let timeZoneId: String

    public init(
        postalCode: String,
        city: String?,
        state: String?,
        countryCode: String?,
        lat: Double,
        lng: Double,
        timeZoneId: String
    ) {
        self.postalCode = postalCode
        self.city = city
        self.state = state
        self.countryCode = countryCode
        self.lat = lat
        self.lng = lng
        self.timeZoneId = timeZoneId
    }
}

/// POST /api/v1/auth/register — request body for a CLIENT signup. Mirrors the web
/// client signup (SignupClientClient): name + geocoded ZIP + phone + email +
/// password with the TOS and transactional-SMS consents. `deviceId` is the stable
/// per-install id so the session is revocable per-device. Native sends no
/// `turnstileToken`; the backend's captcha check fails open for it. Pro signup
/// (role "PRO" + a PRO_SALON/PRO_MOBILE location) is a later PR.
struct RegisterRequest: Encodable, Sendable {
    let email: String
    let password: String
    let role: String
    let firstName: String
    let lastName: String
    let phone: String
    let tosAccepted: Bool
    let transactionalSmsConsent: Bool
    let signupLocation: SignupLocationPayload
    let deviceId: String?
}

/// The `signupLocation` wire object. Only the `CLIENT_ZIP` variant is sent today.
struct SignupLocationPayload: Encodable, Sendable {
    let kind: String
    let postalCode: String
    let city: String?
    let state: String?
    let countryCode: String?
    let lat: Double
    let lng: Double
    let timeZoneId: String
}

/// POST /api/v1/auth/register — response (`AuthRegisterResponseDTO`). The `token`
/// is a VERIFICATION-kind JWT: persist it and route into phone verification.
/// (Pro-only license flags on the DTO are ignored here — client signup never
/// triggers them.)
public struct RegisterResponse: Codable, Sendable {
    public let user: AuthUser
    public let token: String
    public let nextUrl: String?
    public let requiresPhoneVerification: Bool
    public let requiresEmailVerification: Bool
    public let isPhoneVerified: Bool
    public let isEmailVerified: Bool
    public let isFullyVerified: Bool
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

/// POST /api/v1/workspace/switch — request body.
struct WorkspaceSwitchRequest: Encodable, Sendable {
    let workspace: String
}

/// POST /api/v1/workspace/switch — response (`WorkspaceSwitchResponseDTO`).
/// `token` is the re-minted JWT carrying the new acting role (native swaps to it).
public struct WorkspaceSwitchResponse: Decodable, Sendable {
    public let workspace: Role
    public let href: String
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