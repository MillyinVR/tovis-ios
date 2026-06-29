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
    public let me: MeService
    public let messages: MessagesService
    public let search: SearchService
    public let discover: DiscoverService
    public let booking: BookingService
    public let addresses: AddressesService
    public let places: PlacesService
    public let checkout: CheckoutService
    public let looks: LooksService
    public let notifications: NotificationsService
    /// PRO workspace — the live-session footer state machine. Only meaningful for
    /// a PRO acting role; CLIENT tokens 403 these endpoints.
    public let proSession: ProSessionService
    /// PRO workspace — the calendar/agenda (bookings + blocks + management).
    public let proCalendar: ProCalendarService
    /// PRO workspace — one booking's detail + management (accept/cancel/rebook).
    public let proBookings: ProBookingService
    /// PRO workspace — the pro's own profile + offerings management.
    public let proProfile: ProProfileService
    /// PRO workspace — session media (before/after photo upload + list).
    public let proMedia: ProMediaService
    public let tokenStore: TokenStore

    /// Stable per-install id. Persisted in the Keychain-backed store's UserDefaults
    /// sibling so it survives launches but resets on reinstall — exactly what
    /// per-device revocation wants.
    public let deviceId: String

    public init(config: TovisConfig, session: URLSession? = nil) {
        let store = TokenStore()
        self.tokenStore = store
        self.deviceId = Self.resolveDeviceId()

        // Native auth is bearer-token (Keychain) based and MUST stay cookieless.
        // `URLSession.shared` has a shared cookie jar that would store the
        // `tovis_token` cookie the backend sets on login and silently resend it.
        // That defeats the server's cookieless-origin exemption: a request that
        // carries a cookie is forced through the CSRF Origin check, and native
        // sends no Origin → 403 INVALID_ORIGIN. So we run on a session with no
        // cookie storage unless the caller injects one (tests).
        let resolvedSession = session ?? Self.makeCookielessSession()

        // The refresh closure is a free function so there's no reference cycle
        // back into APIClient/AuthService.
        let refresh: @Sendable () async -> Bool = {
            await performTokenRefresh(config: config, session: resolvedSession, tokenStore: store)
        }

        let api = APIClient(config: config, session: resolvedSession, tokenStore: store, refresh: refresh)
        self.api = api
        self.auth = AuthService(api: api, tokenStore: store)
        self.devices = DeviceService(api: api)
        self.home = HomeService(api: api)
        self.bookings = BookingsService(api: api)
        self.profiles = ProfileService(api: api)
        self.me = MeService(api: api)
        self.messages = MessagesService(api: api)
        self.search = SearchService(api: api)
        self.discover = DiscoverService(api: api)
        self.booking = BookingService(api: api)
        self.addresses = AddressesService(api: api)
        self.places = PlacesService(api: api)
        self.checkout = CheckoutService(api: api)
        self.looks = LooksService(api: api)
        self.notifications = NotificationsService(api: api)
        self.proSession = ProSessionService(api: api)
        self.proCalendar = ProCalendarService(api: api)
        self.proBookings = ProBookingService(api: api)
        self.proProfile = ProProfileService(api: api)
        self.proMedia = ProMediaService(
            api: api,
            supabaseURL: config.supabaseURL,
            supabaseKey: config.supabaseAnonKey
        )
    }

    /// The signed-in user's id, decoded from the stored JWT. Works on a cold
    /// launch (before `currentUser` is populated) — used to align chat bubbles.
    public func currentUserId() async -> String? {
        guard let token = await tokenStore.token() else { return nil }
        return SessionToken.userId(from: token)
    }

    /// A URLSession that neither stores nor sends cookies — keeps native auth
    /// truly cookieless so the backend's Origin-check exemption always applies.
    private static func makeCookielessSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
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