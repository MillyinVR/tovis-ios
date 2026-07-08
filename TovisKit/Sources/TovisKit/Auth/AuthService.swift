import Foundation

/// Authentication flows: login, token refresh, logout.
///
/// On a successful login the JWT is persisted to the Keychain via `TokenStore`;
/// every authenticated request thereafter replays it as a bearer token.
public final class AuthService: Sendable {
    private let api: APIClient
    private let tokenStore: TokenStore
    private let appAttest: AppAttestProviding

    public init(
        api: APIClient,
        tokenStore: TokenStore,
        appAttest: AppAttestProviding = DeviceCheckAppAttestProvider()
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.appAttest = appAttest
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

    /// POST /api/v1/auth/register — create a CLIENT account. Persists the returned
    /// VERIFICATION-kind token (the account isn't fully verified yet), so the
    /// caller drops into phone verification next. `location` is the ZIP resolved
    /// via `PlacesService.resolveClientZip`. Mirrors the web client signup.
    @discardableResult
    public func registerClient(
        email: String,
        password: String,
        firstName: String,
        lastName: String,
        phone: String,
        location: ClientSignupLocation,
        deviceId: String?
    ) async throws -> RegisterResponse {
        // Bind an App Attest attestation to this exact identity: attest over
        // SHA256("email\nphone\ntimestamp"), then send the same timestamp so the
        // backend recomputes and verifies the binding. Absent on the Simulator.
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
        let clientDataHash = AppAttestClientData.hash(
            email: email,
            phone: phone,
            timestampMs: timestampMs
        )
        let attestation = await appAttest.attest(clientDataHash: clientDataHash)
        let appAttestPayload = attestation.map {
            AppAttestPayload(
                keyId: $0.keyId,
                attestation: $0.attestationBase64,
                timestamp: timestampMs
            )
        }

        let payload = try JSONEncoder().encode(
            RegisterRequest(
                email: email,
                password: password,
                role: Role.client.rawValue,
                firstName: firstName,
                lastName: lastName,
                phone: phone,
                tosAccepted: true,
                transactionalSmsConsent: true,
                signupLocation: SignupLocationPayload(
                    kind: "CLIENT_ZIP",
                    postalCode: location.postalCode,
                    city: location.city,
                    state: location.state,
                    countryCode: location.countryCode,
                    lat: location.lat,
                    lng: location.lng,
                    timeZoneId: location.timeZoneId
                ),
                deviceId: deviceId,
                appAttest: appAttestPayload
            )
        )
        let response: RegisterResponse = try await api.request(
            "/auth/register",
            method: .post,
            body: payload,
            authenticated: false
        )
        await tokenStore.save(response.token)
        return response
    }

    /// POST /api/v1/auth/register — create a PRO account. Same App Attest binding
    /// and VERIFICATION-token handling as `registerClient`, plus the pro fields the
    /// backend's PRO branch requires (profession, licensed/operating state, and a
    /// PRO_SALON / PRO_MOBILE `signupLocation`). `businessName` / `handle` /
    /// `licenseNumber` / `licenseExpiry` are optional (nil → omitted). Mirrors the
    /// web pro signup (SignupProClient).
    @discardableResult
    public func registerPro(
        email: String,
        password: String,
        firstName: String,
        lastName: String,
        phone: String,
        professionType: ProfessionType,
        licenseState: String,
        businessName: String?,
        handle: String?,
        licenseNumber: String?,
        licenseExpiry: String?,
        location: ProSignupLocation,
        deviceId: String?
    ) async throws -> RegisterResponse {
        // Bind the attestation to this identity exactly as registerClient does.
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
        let clientDataHash = AppAttestClientData.hash(
            email: email,
            phone: phone,
            timestampMs: timestampMs
        )
        let attestation = await appAttest.attest(clientDataHash: clientDataHash)
        let appAttestPayload = attestation.map {
            AppAttestPayload(
                keyId: $0.keyId,
                attestation: $0.attestationBase64,
                timestamp: timestampMs
            )
        }

        // Map the location variant to the wire `signupLocation` + mobile radius.
        let signupLocation: SignupLocationPayload
        let mobileRadiusMiles: Int?
        switch location {
        case let .salon(salon):
            signupLocation = SignupLocationPayload(
                kind: "PRO_SALON",
                postalCode: salon.postalCode,
                city: salon.city,
                state: salon.state,
                countryCode: salon.countryCode,
                lat: salon.lat,
                lng: salon.lng,
                timeZoneId: salon.timeZoneId,
                placeId: salon.placeId,
                formattedAddress: salon.formattedAddress
            )
            mobileRadiusMiles = nil
        case let .mobile(zip, radiusMiles):
            signupLocation = SignupLocationPayload(
                kind: "PRO_MOBILE",
                postalCode: zip.postalCode,
                city: zip.city,
                state: zip.state,
                countryCode: zip.countryCode,
                lat: zip.lat,
                lng: zip.lng,
                timeZoneId: zip.timeZoneId
            )
            mobileRadiusMiles = radiusMiles
        }

        let payload = try JSONEncoder().encode(
            RegisterRequest(
                email: email,
                password: password,
                role: Role.pro.rawValue,
                firstName: firstName,
                lastName: lastName,
                phone: phone,
                tosAccepted: true,
                transactionalSmsConsent: true,
                signupLocation: signupLocation,
                deviceId: deviceId,
                appAttest: appAttestPayload,
                professionType: professionType.rawValue,
                licenseState: licenseState,
                businessName: businessName,
                handle: handle,
                mobileRadiusMiles: mobileRadiusMiles,
                licenseNumber: licenseNumber,
                licenseExpiry: licenseExpiry
            )
        )
        let response: RegisterResponse = try await api.request(
            "/auth/register",
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

    /// Switch the acting workspace (CLIENT / PRO / ADMIN). The backend re-mints
    /// the JWT with the new acting role and returns it — native must swap to this
    /// token (web uses the cookie). Saves the new token so the next request acts
    /// in the new role; the caller re-points the shell from the new role.
    /// Entitlement is re-checked server-side (PRO needs an APPROVED profile), so a
    /// 403 means the user can't act there. Mirrors lib/auth/workspaces.ts.
    @discardableResult
    public func switchWorkspace(to role: Role) async throws -> WorkspaceSwitchResponse {
        let payload = try JSONEncoder().encode(WorkspaceSwitchRequest(workspace: role.rawValue))
        let response: WorkspaceSwitchResponse = try await api.request(
            "/workspace/switch", method: .post, body: payload
        )
        await tokenStore.save(response.token)
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