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

// MARK: - Auth state (owns the TovisClient)

@MainActor
@Observable
final class SessionModel {
    enum State: Equatable { case loading, signedOut, signedIn }

    private(set) var state: State = .loading
    private(set) var currentUser: AuthUser?
    var isWorking = false
    var errorMessage: String?

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
        let signedIn = await client.auth.hasSession()
        state = signedIn ? .signedIn : .signedOut
        if signedIn { await startRealtime() }
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
            currentUser = result.user
            state = .signedIn
            await startRealtime()
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
            currentUser = result.user
            state = .signedIn
            await startRealtime()
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
            currentUser = result.user
            state = .signedIn
            await startRealtime()
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Something went wrong. Please try again."
        }
    }

    func logout() async {
        await realtime?.stop()
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
