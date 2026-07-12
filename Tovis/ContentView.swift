// Tovis app — entry point, auth state, and branded screens.
// Styled with the Peacock Plume tokens (Theme/BrandColor + BrandFont).
import SwiftUI
import TovisKit
import AuthenticationServices
import UIKit

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
/// single internal path (e.g. "/client/bookings/bk_1?step=aftercare"); we map it
/// to the native surface the app can open. Unrecognized paths yield `nil` (no-op
/// tap — the app just foregrounds). The path prefix (`client`/`pro`) also tells us
/// which shell owns the target, so a tap can switch workspaces first (see `role`).
struct PushDeepLink: Equatable {
    enum Target: Equatable {
        // Shared — either shell resolves these in place (no workspace switch).
        case thread(id: String)              // /messages/thread/{id}
        case look(id: String)                // /looks/{id}

        // Client-shell targets.
        case booking(id: String, step: String?)  // /client/bookings/{id}?step=… (#review → "review")
        case offers(accept: String?)         // /client/offers?accept={recipientId}
        case referrals                       // /client/referrals
        case activity                        // /client/activity
        case clientHome                      // any other /client/*

        // Pro-shell targets.
        case proBooking(id: String, step: String?)  // /pro/bookings/{id}[/session|/aftercare|…]
        case proReviews(id: String?)         // /pro/reviews[/{id}] or #review-{id}
        case membership                      // /pro/membership
        case proProfile                      // /pro/profile/public-profile
        case proCalendar                     // /pro/calendar
        case proHome                         // any other /pro/*
    }

    let target: Target

    /// The role whose shell owns this target, or `nil` when either shell can open
    /// it (thread, look). When it differs from the acting role, the shell asks the
    /// session to `switchWorkspace(to:)` and leaves the link buffered so the newly
    /// mounted shell consumes it.
    var role: Role? {
        switch target {
        case .thread, .look:
            return nil
        case .booking, .offers, .referrals, .activity, .clientHome:
            return .client
        case .proBooking, .proReviews, .membership, .proProfile, .proCalendar, .proHome:
            return .pro
        }
    }

    init?(href: String) {
        // Mirror `CheckoutReturn`: parse with URLComponents so the query (`?step=`)
        // and fragment (`#review`) survive instead of being dropped. `.path` is
        // percent-decoded, which is what the native id-based fetches expect. Some
        // emitted hrefs have surrounding whitespace — trim before parsing.
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed) else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        let step = comps.queryItems?.first(where: { $0.name == "step" })?.value
        let fragment = comps.fragment

        guard let first = parts.first else { return nil }
        switch first {
        // /messages/thread/{id} → the conversation. Both roles use this path; the
        // active shell resolves the thread.
        case "messages":
            if parts.count >= 3, parts[1] == "thread" { target = .thread(id: parts[2]); return }
            return nil

        // /looks/{id} → the look. No native single-look detail yet, so the shell
        // falls back to the Looks feed; the id is carried for a future detail view.
        case "looks":
            if parts.count >= 2 { target = .look(id: parts[1]); return }
            return nil

        case "client":
            guard parts.count >= 2 else { target = .clientHome; return }
            switch parts[1] {
            case "bookings" where parts.count >= 3:
                // A `#review` fragment is folded into `step` so the target is
                // distinct and a future scroll-to-section can use it.
                target = .booking(id: parts[2], step: step ?? (fragment == "review" ? "review" : nil))
            case "offers":
                // The priority-offer push is `/client/offers?accept={recipientId}`;
                // carry that id so the offers screen floats + highlights it.
                target = .offers(accept: comps.queryItems?.first(where: { $0.name == "accept" })?.value)
            case "referrals": target = .referrals
            case "activity":  target = .activity
            default:          target = .clientHome
            }
            return

        case "pro":
            guard parts.count >= 2 else { target = .proHome; return }
            switch parts[1] {
            case "bookings" where parts.count >= 3:
                // The 4th segment (session|aftercare|before-photos|…) is the step;
                // `nil` = the plain booking detail. Carried for a future step-jump.
                target = .proBooking(id: parts[2], step: parts.count >= 4 ? parts[3] : nil)
            case "reviews":
                // /pro/reviews/{id} (path) or /pro/reviews#review-{id} — the
                // review-received push mirrors the web `review-<id>` anchor in the
                // fragment. Prefer an explicit path segment; else lift the id out of
                // the `review-<id>` fragment so the list can scroll to that review.
                let reviewId = parts.count >= 3
                    ? parts[2]
                    : fragment.flatMap { (frag: String) -> String? in
                        guard frag.hasPrefix("review-") else { return nil }
                        let id = String(frag.dropFirst("review-".count))
                        return id.isEmpty ? nil : id
                    }
                target = .proReviews(id: reviewId)
            case "membership": target = .membership
            case "profile":    target = .proProfile   // /pro/profile/public-profile
            case "calendar":   target = .proCalendar
            default:           target = .proHome
            }
            return

        // /terms, /u/{handle}, external links, /admin/*, etc. → no native surface.
        default:
            return nil
        }
    }
}

// MARK: - Password-reset Universal Link

/// A parsed `https://<host>/reset-password/<token>` Universal Link — the link
/// `lib/auth/passwordReset` emails. With the app installed, iOS hands the tap to
/// `.onOpenURL` (the AASA scopes it to `/reset-password/*`); we pull the token and
/// route to the native set-new-password screen instead of the web page. The host
/// is re-checked defensively — never trust an arbitrary https URL from onOpenURL.
struct PasswordResetLink: Equatable {
    let token: String

    init?(url: URL) {
        guard url.scheme?.lowercased() == "https" else { return nil }
        let host = url.host?.lowercased()
        guard host == "tovis.app" || host == "www.tovis.app" else { return nil }
        // Path segments minus the leading "/": ["reset-password", "<token>"].
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "reset-password" else { return nil }
        let token = parts[1]
        guard !token.isEmpty else { return nil }
        self.token = token
    }
}

// MARK: - Public-board Universal Link

/// A parsed `https://<host>/u/<handle>/boards/<slug>` Universal Link — the share
/// link `BoardShareSection` generates. With the app installed, iOS hands the tap
/// to `.onOpenURL`; we pull the handle + slug and present the native public-board
/// viewer instead of the web page. The host is re-checked defensively — never
/// trust an arbitrary https URL from onOpenURL.
struct PublicBoardLink: Equatable {
    let handle: String
    let slug: String

    init?(url: URL) {
        guard url.scheme?.lowercased() == "https" else { return nil }
        let host = url.host?.lowercased()
        guard host == "tovis.app" || host == "www.tovis.app" else { return nil }
        // Path segments minus the leading "/": ["u", "<handle>", "boards", "<slug>"].
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[0] == "u", parts[2] == "boards" else { return nil }
        let handle = parts[1]
        let slug = parts[3]
        guard !handle.isEmpty, !slug.isEmpty else { return nil }
        self.handle = handle
        self.slug = slug
    }
}

// MARK: - Client-claim Universal Link

/// A parsed `https://<host>/claim/<token>` Universal Link — the claim link a pro
/// texts/emails an unclaimed client. With the app installed, iOS hands the tap to
/// `.onOpenURL`; we pull the token and present the native claim screen (which reads
/// the booking context and routes into signup with intent=CLAIM_INVITE) instead of
/// the web page. The host is re-checked defensively — never trust an arbitrary
/// https URL from onOpenURL.
struct PublicClaimLink: Equatable {
    let token: String

    init?(url: URL) {
        guard url.scheme?.lowercased() == "https" else { return nil }
        let host = url.host?.lowercased()
        guard host == "tovis.app" || host == "www.tovis.app" else { return nil }
        // Path segments minus the leading "/": ["claim", "<token>"].
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "claim" else { return nil }
        let token = parts[1]
        guard !token.isEmpty else { return nil }
        self.token = token
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
    /// The role the session is acting in — drives which shell shows (client vs
    /// pro). On a fresh sign-in it comes from the login response; on a cold launch
    /// it's decoded from the stored JWT (no network call), then reconciled by
    /// `currentUser` once a screen loads /me. Defaults to client (the common case)
    /// so an unreadable/legacy token still lands somewhere sane.
    private(set) var activeRole: Role = .client
    var isWorking = false
    var errorMessage: String?

    /// Whether the partial session's EMAIL is already verified (Apple sets this),
    /// so the verification screen knows phone is the only step left.
    private(set) var emailVerified = false

    /// Whether the partial session's PHONE is already verified. During the
    /// post-signup verification phase this decides which step the verify screen
    /// shows: phone not done → the code step; phone done but email still pending
    /// (the email/password path) → the email step. Set from the phone-verify
    /// result and the status poll.
    private(set) var phoneVerified = false

    /// The account email the verification link was sent to — shown on the email
    /// step so the user knows where to look. Populated by the status poll.
    private(set) var verificationEmail: String?

    /// The phone captured during native signup. When set, the post-signup
    /// verification screen opens straight at the code step (the register endpoint
    /// already texted the code) instead of asking for the number again. nil for
    /// the Apple path, which has no phone on file yet.
    private(set) var pendingVerificationPhone: String?

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

    /// The token from a tapped password-reset Universal Link. RootView presents the
    /// native set-new-password screen over whatever is showing when this is set
    /// (works from a cold launch too — the cover survives the bootstrap swap).
    private(set) var pendingPasswordResetToken: String?

    /// The handle + slug from a tapped public-board Universal Link
    /// (`/u/<handle>/boards/<slug>`). RootView presents the native public-board
    /// viewer over whatever is showing (cold-launch safe, like the reset cover).
    private(set) var pendingPublicBoard: PublicBoardLink?

    /// The token from a tapped client-claim Universal Link (`/claim/<token>`).
    /// RootView presents the native claim screen over whatever is showing
    /// (cold-launch + signed-out safe, like the reset cover).
    private(set) var pendingClaim: PublicClaimLink?

    /// Set when a plain client signup matched pro-created history and the backend
    /// sent a claim link to the on-file contact instead of creating an account
    /// (409 CLAIMABLE_HISTORY). The signup screen shows this as a "check your
    /// email/text" message rather than an error. Mirrors the web check-inbox state.
    private(set) var claimableHistoryMessage: String?

    /// Handle an incoming deep link / Universal Link. Password-reset + public-board
    /// links route to their native screens; the `tovis://checkout/return?…` scheme
    /// feeds the active booking screen. Anything else is ignored so stray links are
    /// safe.
    func handleDeepLink(_ url: URL) {
        if let reset = PasswordResetLink(url: url) {
            pendingPasswordResetToken = reset.token
            return
        }
        if let board = PublicBoardLink(url: url) {
            pendingPublicBoard = board
            return
        }
        if let claim = PublicClaimLink(url: url) {
            pendingClaim = claim
            return
        }
        guard let parsed = CheckoutReturn(url: url) else { return }
        checkoutReturn = parsed
        signalRefresh()
    }

    /// Acknowledge a return once the active screen has consumed it.
    func clearCheckoutReturn() { checkoutReturn = nil }

    /// Dismiss the native set-new-password screen (done or cancelled).
    func clearPasswordResetToken() { pendingPasswordResetToken = nil }

    /// Dismiss the native public-board viewer.
    func clearPublicBoard() { pendingPublicBoard = nil }

    /// Dismiss the native claim screen.
    func clearClaim() { pendingClaim = nil }

    /// Clear the cold-claim "check your email/text" message (e.g. on retry/back).
    func clearClaimableHistory() { claimableHistoryMessage = nil }

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
        // Cold-launch: pick the shell from the JWT's acting-role claim so the pro
        // bar shows immediately, with no network round-trip (reconciled later).
        if let token = await client.tokenStore.token(),
           let role = SessionToken.role(from: token) {
            activeRole = role
        }
        state = .signedIn
        await startRealtime()
        await startPush()
    }

    /// Re-read the acting role from the freshly stored JWT after a workspace
    /// switch (`POST /api/v1/workspace/switch` re-mints the token) and re-point
    /// the shell. No-op if the token can't be read.
    func reloadActiveRole() async {
        guard let token = await client.tokenStore.token(),
              let role = SessionToken.role(from: token) else { return }
        activeRole = role
    }

    /// Switch the acting workspace (e.g. pro → client). Re-mints the token
    /// server-side, then flips `activeRole` so RootView swaps the shell. Mirrors
    /// the web workspace switcher; entitlement is enforced by the backend.
    func switchWorkspace(to role: Role) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await client.auth.switchWorkspace(to: role)
            activeRole = result.workspace
            signalRefresh()
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn’t switch workspace. Please try again."
        }
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
        activeRole = result.user.role
        emailVerified = result.isEmailVerified
        phoneVerified = result.isPhoneVerified
        verificationEmail = result.user.email
        // Login/Apple/phone paths carry no signup phone — clear any stale prefill
        // so the verification screen (if reached) asks for the number.
        pendingVerificationPhone = nil
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
    /// persisted and we drop into the app. When phone is done but email is still
    /// pending (the email/password path), there's no dead-end: the verify screen
    /// advances to its email step, driven by `phoneVerified && !emailVerified`.
    func verifyPhoneCode(_ code: String) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await client.auth.verifyAccountPhone(code: code)
            phoneVerified = result.isPhoneVerified
            emailVerified = result.isEmailVerified
            if result.isFullyVerified {
                state = .signedIn
                await startRealtime()
                await startPush()
            }
            // else: phone verified, email still required — the screen moves to the
            // email step; the status poll finishes the flow once the link is tapped.
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "That code didn’t work. Please try again."
        }
    }

    // MARK: - In-app verification (email)

    /// Poll the post-signup verification status. AuthService persists the healed
    /// ACTIVE token when the backend returns one, so once the account is fully
    /// verified with an ACTIVE session we drop into the app. Advancing is gated on
    /// `sessionKind == "ACTIVE"` (not `isFullyVerified` alone): the stored token
    /// must be the ACTIVE one or every authenticated app request would 403.
    /// Returns true if it advanced to `.signedIn`. Also syncs the UI flags.
    @discardableResult
    func refreshVerificationStatus() async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let status = try await client.auth.verificationStatus()
            phoneVerified = status.isPhoneVerified
            emailVerified = status.isEmailVerified
            verificationEmail = status.user.email
            if status.isFullyVerified, status.sessionKind == "ACTIVE" {
                state = .signedIn
                await startRealtime()
                await startPush()
                return true
            }
            return false
        } catch let error as APIError {
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = "Couldn’t check your verification. Please try again."
            return false
        }
    }

    /// (Re)send the email-verification link to the account email. If the email is
    /// already verified, re-poll so we advance without another tap. Returns true
    /// when the request was accepted (false surfaces the backend message).
    @discardableResult
    func resendVerificationEmail() async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await client.auth.sendEmailVerification()
            if result.isEmailVerified {
                _ = await refreshVerificationStatus()
            }
            return true
        } catch let error as APIError {
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = "Couldn’t resend the email. Please try again."
            return false
        }
    }

    /// Bail out of verification (back to the sign-in screen).
    func cancelVerification() async {
        await client.auth.logout()
        currentUser = nil
        emailVerified = false
        phoneVerified = false
        verificationEmail = nil
        pendingVerificationPhone = nil
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

    // MARK: - Password reset

    /// Request a password-reset email. Enumeration-safe: the backend always
    /// accepts, so `true` only means "we sent the request" (the email arrives only
    /// if the account exists). Returns false on a transport / rate-limit failure.
    func requestPasswordReset(email: String) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await client.auth.requestPasswordReset(email: email)
            return true
        } catch let error as APIError {
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = "Couldn’t send the reset email. Please try again."
            return false
        }
    }

    /// Set a new password from a reset-link token. Returns true on success (the
    /// caller dismisses back to sign-in). Surfaces the backend message on failure
    /// (expired / used link, or a password that fails the policy).
    func confirmPasswordReset(token: String, password: String) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await client.auth.confirmPasswordReset(token: token, password: password)
            return true
        } catch let error as APIError {
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = "Couldn’t update your password. Please try again."
            return false
        }
    }

    /// Create a CLIENT account (native email/password signup). On success the
    /// account is signed in but unverified: the returned VERIFICATION token is
    /// persisted and we route to phone verification. The register endpoint has
    /// already texted the code, so `pendingVerificationPhone` lets that screen
    /// skip straight to code entry. Returns true so the caller can dismiss the
    /// signup flow.
    ///
    /// `intent`/`inviteToken` are set from the claim flow (`intent = "CLAIM_INVITE"`)
    /// so the backend ADOPTS the pro's existing unclaimed profile. For a PLAIN
    /// signup whose contact matches pro-created history, the backend returns
    /// 409 CLAIMABLE_HISTORY and mails/texts a claim link instead of creating the
    /// account — surfaced via `claimableHistoryMessage` (not an error).
    func registerClient(
        email: String,
        password: String,
        firstName: String,
        lastName: String,
        phone: String,
        location: ClientSignupLocation,
        intent: String? = nil,
        inviteToken: String? = nil
    ) async -> Bool {
        isWorking = true
        errorMessage = nil
        claimableHistoryMessage = nil
        defer { isWorking = false }
        do {
            let result = try await client.auth.registerClient(
                email: email,
                password: password,
                firstName: firstName,
                lastName: lastName,
                phone: phone,
                location: location,
                deviceId: client.deviceId,
                intent: intent,
                inviteToken: inviteToken
            )
            currentUser = result.user
            activeRole = result.user.role
            emailVerified = result.isEmailVerified
            phoneVerified = result.isPhoneVerified
            verificationEmail = result.user.email
            pendingVerificationPhone = phone
            state = .needsVerification
            return true
        } catch let error as APIError {
            if case let .server(status, message, code) = error,
               status == 409, code == "CLAIMABLE_HISTORY" {
                claimableHistoryMessage = message
                    ?? "We found existing history for this contact. Check your email or text for a secure link to finish setting up your account."
                return false
            }
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = "Couldn’t create your account. Please try again."
            return false
        }
    }

    /// Create a PRO account (native pro signup). Same post-signup path as
    /// `registerClient`: the returned VERIFICATION token is persisted and we route
    /// to phone verification (the register endpoint already texted the code, so
    /// `pendingVerificationPhone` skips straight to code entry). Returns true so the
    /// caller can dismiss the signup flow.
    func registerPro(
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
        location: ProSignupLocation
    ) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await client.auth.registerPro(
                email: email,
                password: password,
                firstName: firstName,
                lastName: lastName,
                phone: phone,
                professionType: professionType,
                licenseState: licenseState,
                businessName: businessName,
                handle: handle,
                licenseNumber: licenseNumber,
                licenseExpiry: licenseExpiry,
                location: location,
                deviceId: client.deviceId
            )
            currentUser = result.user
            activeRole = result.user.role
            emailVerified = result.isEmailVerified
            phoneVerified = result.isPhoneVerified
            verificationEmail = result.user.email
            pendingVerificationPhone = phone
            state = .needsVerification
            return true
        } catch let error as APIError {
            errorMessage = error.userMessage
            return false
        } catch {
            errorMessage = "Couldn’t create your pro account. Please try again."
            return false
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
        emailVerified = false
        phoneVerified = false
        verificationEmail = nil
        pendingVerificationPhone = nil
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
                // The acting role picks the shell — mirrors the web RoleFooter,
                // which renders the pro/client/admin footer from the same role.
                // ADMIN has no native shell yet, so it falls through to client.
                if session.activeRole == .pro {
                    ProMainTabView()
                } else {
                    MainTabView()
                }
            }
        }
        // Stripe Checkout hands back through the `tovis://checkout/return` scheme
        // (via the backend bounce page). Route it into the session so the active
        // booking screen can dismiss the browser and refetch. A tapped
        // password-reset Universal Link routes through the same handler.
        .onOpenURL { session.handleDeepLink($0) }
        // A tapped password-reset link opens the native set-new-password screen
        // over whatever is showing (even mid-launch — the token survives the
        // bootstrap state swap), mirroring the web /reset-password/<token> page.
        .fullScreenCover(isPresented: Binding(
            get: { session.pendingPasswordResetToken != nil },
            set: { if !$0 { session.clearPasswordResetToken() } }
        )) {
            if let token = session.pendingPasswordResetToken {
                ResetPasswordView(token: token)
            }
        }
        // A tapped `/u/{handle}/boards/{slug}` share link opens the native
        // public-board viewer over whatever is showing (wrapped in its own
        // NavigationStack so the owner back-link can push the creator profile).
        .fullScreenCover(isPresented: Binding(
            get: { session.pendingPublicBoard != nil },
            set: { if !$0 { session.clearPublicBoard() } }
        )) {
            if let board = session.pendingPublicBoard {
                NavigationStack {
                    PublicBoardView(handle: board.handle, slug: board.slug)
                }
            }
        }
        // A tapped `/claim/<token>` link opens the native claim screen over
        // whatever is showing (works signed-out and from a cold launch), mirroring
        // the web /claim/<token> page — read booking context, then create an
        // account to adopt the pro-created history.
        .fullScreenCover(isPresented: Binding(
            get: { session.pendingClaim != nil },
            set: { if !$0 { session.clearClaim() } }
        )) {
            if let claim = session.pendingClaim {
                NavigationStack {
                    ClaimView(token: claim.token)
                }
            }
        }
    }
}

// MARK: - Login

struct LoginView: View {
    @Environment(SessionModel.self) private var session
    @State private var email = ""
    @State private var password = ""
    @State private var showPhone = false
    @State private var showSignup = false
    @State private var showForgot = false

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

                PasswordRevealField(placeholder: "Password", text: $password, textContentType: .password)

                if let message = session.errorMessage {
                    Text(message)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.ember)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("Forgot password?") {
                    session.errorMessage = nil
                    showForgot = true
                }
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(BrandColor.accent)
                .frame(maxWidth: .infinity, alignment: .trailing)
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

            HStack(spacing: 6) {
                Text("New here?")
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textMuted)
                Button("Create an account") {
                    session.errorMessage = nil
                    showSignup = true
                }
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(BrandColor.accent)
            }
            .padding(.top, 2)

            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .sheet(isPresented: $showPhone) {
            PhoneLoginView()
        }
        .sheet(isPresented: $showForgot) {
            ForgotPasswordView()
        }
        .fullScreenCover(isPresented: $showSignup) {
            SignupRoleChooserView()
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
    /// Optional keyboard/content-type hints so a caller can request the right
    /// keyboard (phone pad, URL, …) and autofill without duplicating the styling.
    /// All default to the plain-text behavior the existing call sites rely on.
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType? = nil
    var autocapitalization: TextInputAutocapitalization? = nil
    var autocorrectionDisabled: Bool = false

    var body: some View {
        Group {
            if isSecure {
                SecureField("", text: $text, prompt: prompt)
            } else {
                TextField("", text: $text, prompt: prompt)
            }
        }
        .keyboardType(keyboardType)
        .textContentType(textContentType)
        .textInputAutocapitalization(autocapitalization)
        .autocorrectionDisabled(autocorrectionDisabled)
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
