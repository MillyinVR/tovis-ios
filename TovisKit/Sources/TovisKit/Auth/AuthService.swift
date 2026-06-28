import Foundation

/// Authentication flows: login, token refresh, logout.
///
/// On a successful login the JWT is persisted to the Keychain via `TokenStore`;
/// every authenticated request thereafter replays it as a bearer token.
public final class AuthService: Sendable {
    private let api: APIClient
    private let tokenStore: TokenStore

    public init(api: APIClient, tokenStore: TokenStore) {
        self.api = api
        self.tokenStore = tokenStore
    }

    /// POST /api/v1/auth/login. Persists the returned token on success.
    /// Pass the stable per-install `deviceId` so the session is revocable per-device.
    @discardableResult
    public func login(email: String, password: String, deviceId: String?) async throws -> LoginResponse {
        let payload = try JSONEncoder().encode(
            LoginRequest(email: email, password: password, deviceId: deviceId)
        )
        let response: LoginResponse = try await api.request(
            "/auth/login",
            method: .post,
            body: payload,
            authenticated: false
        )
        await tokenStore.save(response.token)
        return response
    }

    /// POST /api/v1/auth/apple. Send Apple's identity token (+ name on first
    /// auth). Persists the returned session token on success.
    @discardableResult
    public func appleLogin(
        identityToken: String,
        firstName: String?,
        lastName: String?,
        deviceId: String?
    ) async throws -> LoginResponse {
        let payload = try JSONEncoder().encode(
            AppleLoginRequest(
                identityToken: identityToken,
                deviceId: deviceId,
                firstName: firstName,
                lastName: lastName
            )
        )
        let response: LoginResponse = try await api.request(
            "/auth/apple",
            method: .post,
            body: payload,
            authenticated: false
        )
        await tokenStore.save(response.token)
        return response
    }

    /// POST /api/v1/auth/phone-login/send. Requests an SMS code. The response is
    /// intentionally generic (it never reveals whether the number has an account).
    @discardableResult
    public func phoneLoginSend(phone: String) async throws -> PhoneLoginSendResponse {
        let payload = try JSONEncoder().encode(PhoneLoginSendRequest(phone: phone))
        return try await api.request(
            "/auth/phone-login/send",
            method: .post,
            body: payload,
            authenticated: false
        )
    }

    /// POST /api/v1/auth/phone-login/verify. Verifies the SMS code and, on
    /// success, persists the returned session token.
    @discardableResult
    public func phoneLoginVerify(
        phone: String,
        code: String,
        deviceId: String?
    ) async throws -> LoginResponse {
        let payload = try JSONEncoder().encode(
            PhoneLoginVerifyRequest(phone: phone, code: code, deviceId: deviceId)
        )
        let response: LoginResponse = try await api.request(
            "/auth/phone-login/verify",
            method: .post,
            body: payload,
            authenticated: false
        )
        await tokenStore.save(response.token)
        return response
    }

    // MARK: - Account phone verification (post-signup)
    //
    // For a freshly created account that isn't fully verified yet (e.g. after Sign
    // in with Apple, which verifies the email but not a phone). These run on the
    // authenticated verification session (bearer token already stored).

    /// POST /api/v1/auth/phone/correct — set the account's phone number AND send
    /// an SMS code to it. Use this to (re)set the phone before verifying.
    public func setAccountPhoneAndSendCode(phone: String) async throws {
        let payload = try JSONEncoder().encode(PhoneCorrectRequest(phone: phone))
        try await api.requestVoid("/auth/phone/correct", method: .post, body: payload)
    }

    /// POST /api/v1/auth/phone/send — resend the code to the phone already on file.
    public func resendAccountPhoneCode() async throws {
        try await api.requestVoid("/auth/phone/send", method: .post, body: Data("{}".utf8))
    }

    /// POST /api/v1/auth/phone/verify — check the SMS code. On full verification
    /// the backend mints a new ACTIVE token, which we persist so the next request
    /// carries the verified session.
    @discardableResult
    public func verifyAccountPhone(code: String) async throws -> PhoneVerifyResponse {
        let payload = try JSONEncoder().encode(PhoneVerifyCodeRequest(code: code))
        let response: PhoneVerifyResponse = try await api.request(
            "/auth/phone/verify", method: .post, body: payload
        )
        if let token = response.token { await tokenStore.save(token) }
        return response
    }

    /// Forget the session locally. (Also call DeviceService.unregister first if
    /// you want to stop pushes to this device server-side.)
    public func logout() async {
        await tokenStore.clear()
    }

    /// Whether a session token is present (does NOT validate it server-side).
    public func hasSession() async -> Bool {
        await tokenStore.hasToken()
    }

    /// The stored session's kind ("ACTIVE" = fully verified, "VERIFICATION" =
    /// partial post-signup). Read locally from the JWT — no network call.
    public func sessionKind() async -> String? {
        guard let token = await tokenStore.token() else { return nil }
        return SessionToken.sessionKind(from: token)
    }
}

/// Stateless token refresh used by `APIClient`'s 401 handler.
///
/// Lives as a free function (not on `AuthService`) so `APIClient` can call it
/// without a retain cycle: it talks to the backend directly with the current
/// bearer token and saves the new one. Returns true on success.
func performTokenRefresh(
    config: TovisConfig,
    session: URLSession,
    tokenStore: TokenStore
) async -> Bool {
    guard let current = await tokenStore.token() else { return false }

    let url = config.baseURL.appendingPathComponent("auth/refresh")
    var request = URLRequest(url: url)
    request.httpMethod = HTTPMethod.post.rawValue
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(current)", forHTTPHeaderField: "Authorization")

    do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(RefreshResponse.self, from: data)
        else {
            return false
        }
        await tokenStore.save(decoded.token)
        return true
    } catch {
        return false
    }
}