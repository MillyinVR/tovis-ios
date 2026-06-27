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

/// POST /api/v1/auth/refresh — response (`AuthRefreshResponseDTO`).
public struct RefreshResponse: Codable, Sendable {
    public let token: String
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