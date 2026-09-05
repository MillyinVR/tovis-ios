// Push / APNs (Track B). Bridges the UIKit remote-notification callbacks to the
// backend DeviceService so a signed-in device receives the same notifications
// the in-app center shows. The backend push pipeline (APNs sender + cron drain +
// token invalidation) is already built + deployed; it lights up once (a) the
// operator sets APNS_* creds and (b) this code registers a token.
//
// SwiftUI owns the app lifecycle, so `AppDelegate` (a UIApplicationDelegateAdaptor)
// forwards the APNs device token here; `SessionModel` wires the client + the same
// per-install deviceId used for login (so per-device revocation lines up) on
// sign-in, and tears it down on logout.
import UIKit
import UserNotifications
import TovisKit

@MainActor
final class PushManager {
    static let shared = PushManager()
    private init() {}

    private var client: TovisClient?
    private var deviceId: String?
    /// The latest APNs token as a lowercase hex string (what the backend stores).
    private var latestToken: String?
    /// Bumped on an incoming push so the active surface refetches (like live-sync).
    private var onActivity: (@Sendable () -> Void)?
    /// Called when the user TAPS a push, with the payload's `href` deep-link path
    /// (e.g. "/client/bookings/bk_1") — the session routes it to the right screen.
    private var onDeepLink: (@Sendable (String) -> Void)?
    /// A tap that arrived before `enable` wired `onDeepLink` — e.g. a COLD-LAUNCH
    /// tap, where the OS delivers it before sign-in/bootstrap runs. Flushed once
    /// `enable` connects the handler so the launch tap still lands.
    private var pendingDeepLinkHref: String?

    /// Call on sign-in. Asks for notification permission, then registers for
    /// remote notifications; the token arrives asynchronously via `didRegister`.
    /// No-op-safe to call again on every launch (authorization is idempotent and
    /// tokens can rotate, so re-registering is correct).
    func enable(
        client: TovisClient,
        deviceId: String,
        onActivity: @escaping @Sendable () -> Void,
        onDeepLink: @escaping @Sendable (String) -> Void
    ) async {
        self.client = client
        self.deviceId = deviceId
        self.onActivity = onActivity
        self.onDeepLink = onDeepLink

        // Flush a tap that landed before we had a handler (cold-launch tap).
        if let pendingDeepLinkHref {
            self.pendingDeepLinkHref = nil
            onDeepLink(pendingDeepLinkHref)
        }

        #if DEBUG
        // DEBUG ONLY — the Simulator has no synthetic-tap path (see
        // `ContentView`'s `TOVIS_DEBUG_OPEN_EXPORT` and friends), so the
        // system permission alert this triggers is a modal nothing on this
        // machine can dismiss — it blocks every screen behind it, forever.
        // Skipping it here (not at the `startPush()` call site) keeps
        // `enable`'s actual contract — ask, then register — untouched for
        // every other caller and for Release, where this branch doesn't exist.
        if ProcessInfo.processInfo.environment["TOVIS_DEBUG_SKIP_PUSH_PROMPT"] == "1" { return }
        #endif
        let center = UNUserNotificationCenter.current()
        let granted =
            (try? await center.requestAuthorization(options: [.alert, .badge, .sound]))
            ?? false
        guard granted else { return }

        UIApplication.shared.registerForRemoteNotifications()

        // If the token already arrived this launch (fast path), register it now.
        if let latestToken { await sendRegistration(token: latestToken) }
    }

    /// Call on logout. Removes this device server-side (so it stops receiving
    /// pushes) and locally.
    func disable() async {
        if let client, let deviceId, let token = latestToken {
            try? await client.devices.unregister(apnsToken: token, deviceId: deviceId)
        }
        UIApplication.shared.unregisterForRemoteNotifications()
        client = nil
        deviceId = nil
        onActivity = nil
        onDeepLink = nil
        pendingDeepLinkHref = nil
    }

    /// APNs returned a device token (from the AppDelegate). Persist + register it.
    func didRegister(tokenData: Data) {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        latestToken = hex
        Task { await sendRegistration(token: hex) }
    }

    /// A push arrived (foreground or tap) — nudge the app to refetch, mirroring
    /// the live-sync refresh seam so the UI reflects whatever the push announced.
    func handleIncoming() {
        onActivity?()
    }

    /// The user TAPPED a push. Refetch (like `handleIncoming`) AND, if the payload
    /// carries an `href` deep-link path, hand it to the session to route. The
    /// backend sends a single custom key `href` alongside `aps` (no bookingId).
    func handleTap(userInfo: [AnyHashable: Any]) {
        onActivity?()
        guard let href = userInfo["href"] as? String, !href.isEmpty else { return }
        if let onDeepLink { onDeepLink(href) }
        else { pendingDeepLinkHref = href } // flushed when `enable` wires the handler
    }

    private func sendRegistration(token: String) async {
        // Only register while signed in (client+deviceId set by `enable`).
        guard let client, let deviceId else { return }
        try? await client.devices.register(apnsToken: token, deviceId: deviceId)
    }
}

// MARK: - App delegate (remote-notification callbacks)

/// Installed via `@UIApplicationDelegateAdaptor` on the SwiftUI `App`. Only exists
/// to receive the APNs token + notification events and hand them to `PushManager`.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// The system finished (or needs us to finish) background transfers for the
    /// session-photo upload queue, and relaunched us to deal with it.
    ///
    /// ⚠️ `completionHandler` MUST run, on the main thread, once the session says
    /// it has delivered everything — the app is killed for not answering. It is
    /// stored rather than called here because the events themselves arrive later,
    /// via `urlSessionDidFinishEvents`.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            // ⚠️ ROUTE BY IDENTIFIER. There are two background sessions now (pro
            // session media, and the client's consult capture chain), and the
            // completion handler belongs to exactly the one iOS named. Handing
            // it to the wrong queue leaves the real one unanswered — which the
            // app is killed for — and calls the handler before the events it
            // covers have been delivered.
            switch identifier {
            case ConsultCaptureUploadQueue.backgroundSessionIdentifier:
                let uploads = ConsultCaptureUploadQueue.shared
                uploads.backgroundEventsCompletion = completionHandler
                uploads.prepareForBackgroundEvents()
            case SessionUploadQueue.backgroundSessionIdentifier:
                let uploads = SessionUploadQueue.shared
                uploads.backgroundEventsCompletion = completionHandler
                // Register the delegate now. Waiting for the signed-in shell's
                // `configure` would mean waiting on `bootstrap()` — i.e. on the
                // network — before the events this relaunch exists to deliver can
                // arrive at all.
                uploads.prepareForBackgroundEvents()
            default:
                // An identifier neither queue owns. Nothing here can deliver its
                // events — but the handler still MUST run, or the app is killed
                // for not answering a relaunch it was given.
                completionHandler()
            }
        }
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in PushManager.shared.didRegister(tokenData: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Expected until the Push Notifications capability + provisioning are set
        // up (and always on the simulator without a paired push environment).
        // Non-fatal — the in-app center + live-sync still work.
        #if DEBUG
        print("APNs registration failed: \(error.localizedDescription)")
        #endif
    }

    // Show a banner while the app is foregrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in PushManager.shared.handleIncoming() }
        completionHandler([.banner, .badge, .sound])
    }

    // The user tapped a notification — bring the app forward, refetch, and route
    // to the payload's `href` deep link (e.g. the specific booking).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in PushManager.shared.handleTap(userInfo: userInfo) }
        completionHandler()
    }
}
