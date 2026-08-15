import Foundation

/// Environment configuration for the API client.
///
/// `baseURL` points at the backend's versioned API root, i.e. it INCLUDES
/// `/api/v1`. Endpoint paths passed to `APIClient` are then relative, e.g.
/// `"/auth/login"`.
///
/// `supabaseURL` + `supabaseAnonKey` are OPTIONAL and only power live-sync
/// (Supabase Realtime). They're public values (safe to embed). When absent the
/// app falls back to foreground-refresh + polling — nothing breaks.
///
/// `googleClientID` + `googleServerClientID` are OPTIONAL and only power
/// "Continue with Google" (mirrors web's inert-until-provisioned
/// `NEXT_PUBLIC_GOOGLE_CLIENT_ID`). Both are OAuth client ids — public, not
/// secrets (see `lib/auth/googleIdentity.ts`). `googleClientID` is the **iOS**
/// OAuth client id the Google Sign-In SDK runs the flow with; `googleServerClientID`
/// is the **web** OAuth client id (= `GOOGLE_CLIENT_ID` on the backend), which
/// the SDK stamps as the returned id-token's audience so `POST /auth/google`'s
/// verifier accepts it. When either is nil the Google button is hidden and the
/// app relies on Apple / phone / email sign-in — nothing breaks. Provisioning
/// also requires adding the iOS client's reverse-client-id URL scheme to
/// `Tovis/Info.plist` (see the repo README).
public struct TovisConfig: Sendable {
    public let baseURL: URL
    public let supabaseURL: URL?
    public let supabaseAnonKey: String?
    public let googleClientID: String?
    public let googleServerClientID: String?

    public init(
        baseURL: URL,
        supabaseURL: URL? = nil,
        supabaseAnonKey: String? = nil,
        googleClientID: String? = nil,
        googleServerClientID: String? = nil
    ) {
        self.baseURL = baseURL
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.googleClientID = googleClientID
        self.googleServerClientID = googleServerClientID
    }

    /// The web app's origin behind `baseURL` — i.e. `baseURL` with its `/api/v1`
    /// path stripped. Derived rather than configured separately so the two can
    /// never point at different environments: a build talking to a local API opens
    /// local web pages, and a TestFlight build opens the live site.
    ///
    /// Needed because purchasing is web-only (Apple IAP — see the membership
    /// decision log), so the app has to be able to hand a pro off to the site.
    public var webBaseURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? baseURL
    }

    /// A page on the web app, e.g. `webPageURL("/pro/membership")`. Leading slash
    /// optional; a malformed path falls back to the origin rather than trapping.
    public func webPageURL(_ path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !trimmed.isEmpty else { return webBaseURL }
        var components = URLComponents(url: webBaseURL, resolvingAgainstBaseURL: false)
        components?.path = "/" + trimmed
        return components?.url ?? webBaseURL
    }

    /// The Supabase project powering live-sync. This is a PUBLIC publishable key
    /// (the kind designed to ship in client apps) for the same project the
    /// backend uses, so it's safe to embed. Rotate here if the project changes.
    private static let supabaseProjectURL = URL(string: "https://rqhhvuaoksuvbvlypztn.supabase.co")
    private static let supabasePublishableKey = "sb_publishable_uSZDOKvLxbeZnk-6CzoC1w_k2mADwLe"

    /// Google Sign-In OAuth client ids — both nil until provisioned, so the
    /// "Continue with Google" button stays hidden (parity with web's inert
    /// `NEXT_PUBLIC_GOOGLE_CLIENT_ID`). To light it up, from one Google Cloud
    /// project (ids are the same across environments):
    ///   1. Set `googleIOSClientID` to the **iOS** OAuth client id and
    ///      `googleWebClientID` to the **web** OAuth client id
    ///      (= the backend's `GOOGLE_CLIENT_ID` / `NEXT_PUBLIC_GOOGLE_CLIENT_ID`).
    ///   2. Add the iOS client's reverse-client-id (`com.googleusercontent.apps.<id>`)
    ///      as a `CFBundleURLSchemes` entry in `Tovis/Info.plist` so the SDK can
    ///      receive the OAuth redirect.
    /// OAuth client ids are public (not secrets), so embedding them is safe —
    /// same rationale as the Supabase publishable key above.
    private static let googleIOSClientID: String? = nil
    private static let googleWebClientID: String? = nil

    /// Local Next.js dev server (`npm run dev`).
    /// NOTE: plain `http://localhost` requires an App Transport Security
    /// exception in the app's Info.plist (see the repo README).
    ///
    /// Live-sync points at the same Supabase project the local backend uses
    /// (local dev shares the dev Supabase project).
    public static let local = TovisConfig(
        // For physical-device testing, temporarily point this at the Mac's LAN
        // IP (`localhost` on-device = the phone itself) — but never commit
        // that: the IP is machine/network-specific. Prefer the DEBUG launch
        // override below, which needs no edit at all.
        baseURL: localBaseURL,
        supabaseURL: supabaseProjectURL,
        supabaseAnonKey: supabasePublishableKey,
        googleClientID: googleIOSClientID,
        googleServerClientID: googleWebClientID
    )

    private static let defaultLocalBaseURL = URL(string: "http://localhost:3000/api/v1")!

    /// The Debug build's API root, overridable at launch by `TOVIS_DEBUG_API_BASE`:
    ///
    ///     SIMCTL_CHILD_TOVIS_DEBUG_API_BASE=http://localhost:3100/api/v1 \
    ///       xcrun simctl launch <udid> app.tovis.Tovis
    ///
    /// Why it exists: several dev servers run side by side on this machine
    /// (one per worktree), so :3000 is routinely another branch's. Without an
    /// override the only way to point the simulator at YOUR server is to edit
    /// this file — an edit that then has to be remembered and un-made, and the
    /// screen goes unlooked-at when it isn't. Same DEBUG-launch-hook convention
    /// as `TOVIS_DEBUG_TOKEN` / `TOVIS_DEBUG_OPEN_DEEP_LINK`.
    ///
    /// `#if DEBUG` twice over: the constant does not exist in a Release binary,
    /// so a Release build can never be pointed anywhere by an environment
    /// variable. Must include `/api/v1`, like every other `baseURL` here.
    private static var localBaseURL: URL {
        #if DEBUG
            guard
                let raw = ProcessInfo.processInfo.environment["TOVIS_DEBUG_API_BASE"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty,
                let url = URL(string: raw),
                url.scheme == "http" || url.scheme == "https"
            else { return defaultLocalBaseURL }
            return url
        #else
            return defaultLocalBaseURL
        #endif
    }

    /// Production — the live backend at tovis.app. We target the canonical
    /// `www.` host directly: the apex `tovis.app` 307-redirects to
    /// `www.tovis.app`, and a cross-host redirect can drop the `Authorization`
    /// header on URLSession, so we skip it. Serves the same `/api/v1` surface
    /// against the prod Supabase DB the web app uses, so data is shared
    /// between web and iOS.
    public static let production = TovisConfig(
        baseURL: URL(string: "https://www.tovis.app/api/v1")!,
        supabaseURL: supabaseProjectURL,
        supabaseAnonKey: supabasePublishableKey,
        googleClientID: googleIOSClientID,
        googleServerClientID: googleWebClientID
    )
}