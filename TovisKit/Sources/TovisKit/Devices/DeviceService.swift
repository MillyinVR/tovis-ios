import Foundation

/// Push-token registration. Call `register` on launch once you have an APNs
/// token (from `UIApplication`'s `didRegisterForRemoteNotificationsWithDeviceToken`),
/// and `unregister` on logout.
///
/// IMPORTANT: pass the SAME `deviceId` you sent to `AuthService.login` so the
/// auth session and the push device line up for per-device revocation.
public final class DeviceService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// POST /api/v1/devices — register/refresh this device's APNs token.
    public func register(apnsToken: String, deviceId: String) async throws {
        let payload = try JSONEncoder().encode(
            DeviceRegisterRequest(platform: .ios, token: apnsToken, deviceId: deviceId)
        )
        try await api.requestVoid("/devices", method: .post, body: payload)
    }

    /// DELETE /api/v1/devices — stop pushes to this device (call on logout).
    public func unregister(apnsToken: String, deviceId: String) async throws {
        let payload = try JSONEncoder().encode(
            DeviceRegisterRequest(platform: .ios, token: apnsToken, deviceId: deviceId)
        )
        try await api.requestVoid("/devices", method: .delete, body: payload)
    }
}