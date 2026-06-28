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

    /// Call on sign-in. Asks for notification permission, then registers for
    /// remote notifications; the token arrives asynchronously via `didRegister`.
    /// No-op-safe to call again on every launch (authorization is idempotent and
    /// tokens can rotate, so re-registering is correct).
    func enable(
        client: TovisClient,
        deviceId: String,
        onActivity: @escaping @Sendable () -> Void
    ) async {
        self.client = client
        self.deviceId = deviceId
        self.onActivity = onActivity

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

    // The user tapped a notification — bring the app forward + refetch. (Routing
    // to the exact deep link from the payload is a follow-up.)
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in PushManager.shared.handleIncoming() }
        completionHandler()
    }
}
