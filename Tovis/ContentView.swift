// Tovis app — entry point, auth state, and branded screens.
// Styled with the Peacock Plume tokens (Theme/BrandColor + BrandFont).
import SwiftUI
import TovisKit
import AuthenticationServices

// MARK: - App entry point

@main
struct TovisApp: App {
    @State private var session = SessionModel(config: Self.apiConfig)
    @State private var theme = ThemeStore()
    @Environment(\.scenePhase) private var scenePhase
    // Receives the APNs device token + notification callbacks → PushManager (Track B).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Debug builds (simulator / local dev) hit the local backend; Release builds
    /// (TestFlight / App Store) hit production at tovis.app. Both share the prod
    /// Supabase project for live-sync — see TovisConfig.
    private static var apiConfig: TovisConfig {
        #if DEBUG
        return .local
        #else
        return .production
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(theme)
                // System / Light / Dark — follows the device on "system",
                // mirroring the web (lib/brand/theme.ts). Brand default leans
                // dark, but the preference (default .system) drives it.
                .preferredColorScheme(theme.colorScheme)
        }
        // Live-sync Layer 1: whenever the app returns to the foreground, signal
        // every screen to refetch so it never shows stale data after you were on
        // another device. (Layer 2's Realtime subscriber bumps the same seam.)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.signalRefresh() }
        }
    }
}

// MARK: - Checkout deep-link return

/// A parsed `tovis://checkout/return` deep link — the hand-back from the hosted
/// Stripe Checkout page. The backend bounce route (tovis-app app/checkout/return)
/// redirects to this scheme after success/cancel.
struct CheckoutReturn: Equatable {
    enum Status: String { case success, cancelled }
    enum Kind: String { case checkout, deposit }

    let bookingId: String
    let status: Status
    let kind: Kind

    init?(url: URL) {
        guard url.scheme == "tovis", url.host == "checkout" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard let bookingId = value("bookingId"), !bookingId.isEmpty else { return nil }
        self.bookingId = bookingId
        self.status = value("status").flatMap(Status.init) ?? .success
        self.kind = value("kind").flatMap(Kind.init) ?? .checkout
    }
}

// MARK: - Push deep link

/// A tapped push's `href` resolved to an in-app destination. The backend sends a
/// single internal path (e.g. "/client/bookings/bk_1?step=aftercare"); we map the
/// surfaces the client app can open. Unrecognized paths yield `nil` (no-op tap).
struct PushDeepLink: Equatable {
    enum Target: Equatable {
        case booking(id: String)
    }

    let target: Target

    init?(href: String) {
        // Drop any query/fragment, then split the path into segments.
        let pathOnly = href.split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? href
        let parts = pathOnly.split(separator: "/").map(String.init)

        // /client/bookings/{id} → the booking detail.
        if parts.count >= 3, parts[0] == "client", parts[1] == "bookings" {
            target = .booking(id: parts[2])
            return
        }
        return nil
    }
}

// MARK: - Auth state (owns the TovisClient)

@MainActor
@Observable
final class SessionModel {
    enum State: Equatable {
        case loading
        case signedOut
        /// Signed in but not fully verified yet (e.g. Apple sign-in verifies the
        /// email but a phone still needs verifying). Routes to PhoneVerificationView.
        case needsVerification
        case signedIn
    }

    private(set) var state: State = .loading
    private(set) var currentUser: AuthUser?
    var isWorking = false
    var errorMessage: String?

    /// Whether the partial session's EMAIL is already verified (Apple sets this),
    /// so the verification screen knows phone is the only step left.
    private(set) var emailVerified = false

    /// Live-sync seam: every screen observes this and refetches when it changes.
    /// Bumped on app foreground (Layer 1) and on a Realtime "changed" broadcast
    /// (Layer 2). Keeping it on the session means one place wires both triggers.
    private(set) var refreshTick = 0

    func signalRefresh() { refreshTick &+= 1 }

    /// The most recent Stripe Checkout return handed back via the `tovis://`
    /// scheme. The active booking screen observes this, dismisses the in-app
    /// browser, and refetches so the paid state shows. Bumping `signalRefresh`
    /// also nudges every list — and the webhook is the source of truth, so this
    /// is just to surface the result without a manual reload.
    private(set) var checkoutReturn: CheckoutReturn?

    /// Handle a `tovis://checkout/return?status=…&kind=…&bookingId=…` deep link.
    /// Ignores anything that isn't our checkout return so other links are safe.
    func handleDeepLink(_ url: URL) {
        guard let parsed = CheckoutReturn(url: url) else { return }
        checkoutReturn = parsed
        signalRefresh()
    }

    /// Acknowledge a return once the active screen has consumed it.
    func clearCheckoutReturn() { checkoutReturn = nil }

    /// The destination a tapped push asked to open. The signed-in shell observes
    /// this and routes (e.g. presents the booking detail), then clears it. Set
    /// even mid-launch — the shell consumes it once it mounts, so a cold-launch
    /// push tap still lands on the right screen.
    private(set) var pushDeepLink: PushDeepLink?

    /// Handle a tapped push's `href` deep-link path. Ignores paths the client app
    /// can't open (so an unknown link just foregrounds + refreshes, never crashes).
    func handlePushDeepLink(href: String) {
        guard let link = PushDeepLink(href: href) else { return }
        pushDeepLink = link
    }

    /// Acknowledge a deep link once the shell has routed it.
    func clearPushDeepLink() { pushDeepLink = nil }

    let client: TovisClient
    private let realtime: SupabaseRealtime?

    init(config: TovisConfig) {
        self.client = TovisClient(config: config)
        // nil unless Supabase creds are configured — then live-sync is inert and
        // the app relies on foreground-refresh + polling (still fresh).
        self.realtime = SupabaseRealtime(
            supabaseURL: config.supabaseURL,
            anonKey: config.supabaseAnonKey
        )
    }

    func bootstrap() async {
        guard await client.auth.hasSession() else {
            state = .signedOut
            return
        }
        // A partial (post-signup) session carries sessionKind "VERIFICATION";
        // route it to the in-app verification step instead of the app. Read from
        // the stored JWT — no network call. Unknown/legacy tokens default to in.
        if await client.auth.sessionKind() == "VERIFICATION" {
            state = .needsVerification
            return
        }
        state = .signedIn
        await startRealtime()
        await startPush()
    }

    /// Subscribe to this user's live channel. Derives the userId from the stored
    /// JWT so it works on a cold launch too. No-op if realtime isn't configured.
    private func startRealtime() async {
        guard let realtime,
              let token = await client.tokenStore.token(),
              let userId = SessionToken.userId(from: token)
        else { return }

        await realtime.start(channels: ["user:\(userId)"]) {
            Task { @MainActor [weak self] in self?.signalRefresh() }
        }
    }

    /// Track B push: ask for notification permission + register this device's APNs
    /// token (same deviceId as login). An incoming push nudges `refreshTick`, the
    /// same live-sync seam Realtime uses. No-op-safe to call on every sign-in.
    private func startPush() async {
        await PushManager.shared.enable(
            client: client,
            deviceId: client.deviceId,
            onActivity: { [weak self] in
                Task { @MainActor in self?.signalRefresh() }
            },
            onDeepLink: { [weak self] href in
                Task { @MainActor in self?.handlePushDeepLink(href: href) }
            }
        )
    }

    private func stopPush() async {
        await PushManager.shared.disable()
    }

    /// Route a fresh auth response: fully verified → into the app (+ live-sync +
    /// push); otherwise → the in-app verification step.
    private func handleAuthResult(_ result: LoginResponse) async {
        currentUser = result.user
        emailVerified = result.isEmailVerified
        if result.isFullyVerified {
            state = .signedIn
            await startRealtime()
            await startPush()
        } else {
            state = .needsVerification
        }
    }

    // MARK: - In-app verification (phone)

    /// Step 1: set the account phone + send the SMS code. Returns true to advance
    /// to the code entry step.
    func submitVerificationPhone(_ phone: String) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await client.auth.setAccountPhoneAndSendCode(phone: phone)
            return true
        } catch let error as APIError {
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = "Couldn’t send the code. Please try again."
            return false
        }
    }

    /// Resend the code to the phone already on file.
    func resendVerificationCode() async {
        errorMessage = nil
        try? await client.auth.resendAccountPhoneCode()
    }

    /// Step 2: verify the code. On full verification the new ACTIVE token is
    /// persisted and we drop into the app.
    func verifyPhoneCode(_ code: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await client.auth.verifyAccountPhone(code: code)
            if result.isFullyVerified {
                state = .signedIn
                await startRealtime()
                await startPush()
            } else {
                // Phone done but email still pending (not expected for Apple, whose
                // email is pre-verified). Surface it rather than silently looping.
                emailVerified = result.isEmailVerified
                errorMessage = "Your phone is verified. Check your email to finish."
            }
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "That code didn’t work. Please try again."
        }
    }

    /// Bail out of verification (back to the sign-in screen).
    func cancelVerification() async {
        await client.auth.logout()
        currentUser = nil
        emailVerified = false
        state = .signedOut
    }

    func login(email: String, password: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await client.auth.login(
                email: email,
                password: password,
                deviceId: client.deviceId
            )
            await handleAuthResult(result)
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Something went wrong. Please try again."
        }
    }

    func appleLogin(identityToken: String, firstName: String?, lastName: String?) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await client.auth.appleLogin(
                identityToken: identityToken,
                firstName: firstName,
                lastName: lastName,
                deviceId: client.deviceId
            )
            await handleAuthResult(result)
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Something went wrong. Please try again."
        }
    }

    /// Phone-OTP step 1. Returns true if the request was accepted (move to the
    /// code step). The response is generic, so this never reveals account existence.
    func phoneSend(_ phone: String) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            _ = try await client.auth.phoneLoginSend(phone: phone)
            return true
        } catch let error as APIError {
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = "Something went wrong. Please try again."
            return false
        }
    }

    /// Phone-OTP step 2. On success, signs in.
    func phoneVerify(phone: String, code: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await client.auth.phoneLoginVerify(
                phone: phone,
                code: code,
                deviceId: client.deviceId
            )
            await handleAuthResult(result)
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Something went wrong. Please try again."
        }
    }

    func logout() async {
        await realtime?.stop()
        await stopPush() // unregister this device's push token server-side
        await client.auth.logout()
        currentUser = nil
        state = .signedOut
    }
}

// MARK: - Root

struct RootView: View {
    @Environment(SessionModel.self) private var session

    var body: some View {
        ZStack {
            BrandColor.bgPrimary.ignoresSafeArea()

            switch session.state {
            case .loading:
                ProgressView()
                    .tint(BrandColor.accent)
                    .task { await session.bootstrap() }
            case .signedOut:
                LoginView()
            case .needsVerification:
                PhoneVerificationView()
            case .signedIn:
                MainTabView()
            }
        }
        // Stripe Checkout hands back through the `tovis://checkout/return` scheme
        // (via the backend bounce page). Route it into the session so the active
        // booking screen can dismiss the browser and refetch.
        .onOpenURL { session.handleDeepLink($0) }
    }
}

// MARK: - Login

struct LoginView: View {
    @Environment(SessionModel.self) private var session
    @State private var email = ""
    @State private var password = ""
    @State private var showPhone = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 14) {
                TovisEye(size: 76)
                Text("tovis")
                    .font(BrandFont.display(44, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text("The New Age of Self Care")
                    .font(BrandFont.body(15))
                    .foregroundStyle(BrandColor.textMuted)
            }

            VStack(spacing: 12) {
                BrandField(placeholder: "Email", text: $email, isSecure: false)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                BrandField(placeholder: "Password", text: $password, isSecure: true)
                    .textContentType(.password)

                if let message = session.errorMessage {
                    Text(message)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.ember)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button {
                Task { await session.login(email: email, password: password) }
            } label: {
                Group {
                    if session.isWorking {
                        ProgressView().tint(BrandColor.onAccent)
                    } else {
                        Text("Sign in").font(BrandFont.body(17, .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(BrandColor.accent)
                .foregroundStyle(BrandColor.onAccent)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(email.isEmpty || password.isEmpty || session.isWorking)
            .opacity(email.isEmpty || password.isEmpty ? 0.5 : 1)

            HStack(spacing: 12) {
                Rectangle().fill(BrandColor.textMuted.opacity(0.2)).frame(height: 1)
                Text("or").font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                Rectangle().fill(BrandColor.textMuted.opacity(0.2)).frame(height: 1)
            }

            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                handleApple(result)
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Button {
                showPhone = true
            } label: {
                Text("Continue with phone")
                    .font(BrandFont.body(16, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(BrandColor.textMuted.opacity(0.3), lineWidth: 1)
                    )
            }

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .sheet(isPresented: $showPhone) {
            PhoneLoginView()
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case let .success(auth):
            guard
                let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let token = String(data: tokenData, encoding: .utf8)
            else {
                return
            }
            // fullName is only populated on the user's FIRST authorization.
            let first = credential.fullName?.givenName
            let last = credential.fullName?.familyName
            Task {
                await session.appleLogin(identityToken: token, firstName: first, lastName: last)
            }
        case .failure:
            // User canceled or the request failed — leave the screen as-is.
            break
        }
    }
}

/// A brand-styled text/secure field (replaces the default iOS look with the
/// dark surface + subtle border the web uses).
struct BrandField: View {
    let placeholder: String
    @Binding var text: String
    let isSecure: Bool

    var body: some View {
        Group {
            if isSecure {
                SecureField("", text: $text, prompt: prompt)
            } else {
                TextField("", text: $text, prompt: prompt)
            }
        }
        .font(BrandFont.body(16))
        .foregroundStyle(BrandColor.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1)
        )
    }

    private var prompt: Text {
        Text(placeholder).foregroundStyle(BrandColor.textMuted)
    }
}

// The signed-in surface now lives in HomeView (Tovis/HomeView.swift), which
// loads GET /api/v1/client/home and renders the real client home.
