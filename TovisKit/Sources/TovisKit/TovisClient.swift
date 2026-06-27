import Foundation

/// The single entry point the app uses. Wires the API client, secure token
/// store, and the auth/device services together — including the 401→refresh→retry
/// hook.
///
/// Create one at app launch and inject it (e.g. via SwiftUI `.environment`):
///
///     let tovis = TovisClient(config: .local)
///     let result = try await tovis.auth.login(email:..., password:..., deviceId: tovis.deviceId)
public final class TovisClient: Sendable {
    public let api: APIClient
    public let auth: AuthService
    public let devices: DeviceService
    public let home: HomeService
    public let bookings: BookingsService
    public let profiles: ProfileService
    public let tokenStore: TokenStore

    /// Stable per-install id. Persisted in the Keychain-backed store's UserDefaults
    /// sibling so it survives launches but resets on reinstall — exactly what
    /// per-device revocation wants.
    public let deviceId: String

    public init(config: TovisConfig, session: URLSession = .shared) {
        let store = TokenStore()
        self.tokenStore = store
        self.deviceId = Self.resolveDeviceId()

        // The refresh closure is a free function so there's no reference cycle
        // back into APIClient/AuthService.
        let refresh: @Sendable () async -> Bool = {
            await performTokenRefresh(config: config, session: session, tokenStore: store)
        }

        let api = APIClient(config: config, session: session, tokenStore: store, refresh: refresh)
        self.api = api
        self.auth = AuthService(api: api, tokenStore: store)
        self.devices = DeviceService(api: api)
        self.home = HomeService(api: api)
        self.bookings = BookingsService(api: api)
        self.profiles = ProfileService(api: api)
    }

    private static let deviceIdKey = "tovis.deviceId"

    private static func resolveDeviceId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIdKey) {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: deviceIdKey)
        return fresh
    }
}