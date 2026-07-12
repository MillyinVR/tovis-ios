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

/// POST /api/v1/auth/register — request body. Mirrors the web signup forms
/// (SignupClientClient / SignupProClient): name + geocoded location + phone +
/// email + password with the TOS and transactional-SMS consents. `deviceId` is the
/// stable per-install id so the session is revocable per-device. Native can't
/// render Turnstile, so instead of a `turnstileToken` it sends `appAttest` — an
/// Apple App Attest attestation the backend verifies (lib/auth/appAttest.ts).
///
/// The `role`-conditional pro fields (`professionType`, `licenseState`,
/// `businessName`, `handle`, `mobileRadiusMiles`, `licenseNumber`, `licenseExpiry`)
/// are all optional: on a CLIENT signup they're nil and the synthesized encoder
/// omits the keys entirely (`encodeIfPresent`), so the wire body is byte-identical
/// to before. A PRO signup fills the ones its `signupLocation.kind`
/// (PRO_SALON / PRO_MOBILE) requires.
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
    /// Omitted (nil → key absent) when App Attest is unavailable, e.g. the
    /// Simulator; the backend then relies on its local dev fail-open.
    let appAttest: AppAttestPayload?

    // MARK: Claim-invite handoff (nil → key omitted). When a client signs up from
    // a claim link, `intent = "CLAIM_INVITE"` + `inviteToken` let the backend ADOPT
    // the pro's existing unclaimed profile instead of minting a duplicate — see
    // app/api/v1/auth/register/route.ts (adoptClaimInviteDuringRegistration).
    var intent: String? = nil
    var inviteToken: String? = nil

    // MARK: Pro-only fields (nil → key omitted on a CLIENT signup)
    var professionType: String? = nil
    var licenseState: String? = nil
    var businessName: String? = nil
    var handle: String? = nil
    var mobileRadiusMiles: Int? = nil
    var licenseNumber: String? = nil
    var licenseExpiry: String? = nil
}

/// The `appAttest` wire object. `attestation` is the base64 CBOR attestation and
/// `timestamp` is the epoch-millis the client bound into the attested client data
/// (the backend recomputes the same hash to verify the binding + freshness).
struct AppAttestPayload: Encodable, Sendable {
    let keyId: String
    let attestation: String
    let timestamp: Int64
}

/// The `signupLocation` wire object, one shape for all three `kind`s the backend
/// accepts (`CLIENT_ZIP`, `PRO_MOBILE`, `PRO_SALON`). The salon-only fields
/// (`placeId` / `formattedAddress` / `name`) are nil for the ZIP kinds and the
/// encoder drops them; `postalCode` is likewise optional because a picked salon
/// address may not resolve one. See `SignupLocation` in
/// app/api/v1/auth/register/route.ts.
struct SignupLocationPayload: Encodable, Sendable {
    let kind: String
    let postalCode: String?
    let city: String?
    let state: String?
    let countryCode: String?
    let lat: Double
    let lng: Double
    let timeZoneId: String
    // PRO_SALON only (nil → key omitted).
    var placeId: String? = nil
    var formattedAddress: String? = nil
    var name: String? = nil
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

/// GET /api/v1/auth/verification/status — response (`AuthVerificationStatusResponseDTO`).
/// The post-signup verification snapshot the verify screen polls. `token` is
/// non-nil ONLY when this call heals a stale VERIFICATION session into ACTIVE
/// (both factors verified) — native swaps its stored bearer for it, exactly as
/// the phone/verify + email/verify paths do. Null while still pending or already
/// ACTIVE. `sessionKind` is "ACTIVE" once healed; gate the "drop into the app"
/// transition on it so we never advance while the stored token is still a
/// VERIFICATION one (the app's authenticated routes would 403).
public struct VerificationStatusResponse: Decodable, Sendable {
    public struct User: Decodable, Sendable {
        public let id: String
        public let email: String
        public let phone: String?
    }

    public let user: User
    public let sessionKind: String
    public let isPhoneVerified: Bool
    public let isEmailVerified: Bool
    public let isFullyVerified: Bool
    public let requiresPhoneVerification: Bool
    public let requiresEmailVerification: Bool
    public let nextUrl: String?
    public let token: String?
}

/// POST /api/v1/auth/email/send — response. The endpoint answers with either
/// `{ sent: true, … }` (a fresh link was mailed) or `{ alreadyVerified: true, … }`
/// (the email was verified elsewhere first); both carry the current verification
/// flags. We only need to know whether email is already verified so the caller
/// can re-poll status and advance.
public struct EmailVerificationSendResponse: Decodable, Sendable {
    public let sent: Bool?
    public let alreadyVerified: Bool?
    public let isPhoneVerified: Bool
    public let isEmailVerified: Bool
    public let isFullyVerified: Bool
}

// MARK: - Password reset (email-link based)
//
// Mirrors the web flow (app/api/v1/auth/password-reset/*): request emails a link
// carrying a `<tokenId>.<secret>` token, and confirm sets the new password with
// that token. Both bodies are unauthenticated.

/// POST /api/v1/auth/password-reset/request — request body. The endpoint always
/// returns `{ ok: true }` (enumeration-safe), so there's no meaningful response.
struct PasswordResetRequestBody: Encodable, Sendable {
    let email: String
}

/// POST /api/v1/auth/password-reset/confirm — request body. `token` is the
/// `<tokenId>.<secret>` from the emailed reset link (delivered to the app via the
/// `/reset-password/<token>` Universal Link); `password` is the new one.
struct PasswordResetConfirmBody: Encodable, Sendable {
    let token: String
    let password: String
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