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
public struct TovisConfig: Sendable {
    public let baseURL: URL
    public let supabaseURL: URL?
    public let supabaseAnonKey: String?

    public init(baseURL: URL, supabaseURL: URL? = nil, supabaseAnonKey: String? = nil) {
        self.baseURL = baseURL
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
    }

    /// The Supabase project powering live-sync. This is a PUBLIC publishable key
    /// (the kind designed to ship in client apps) for the same project the
    /// backend uses, so it's safe to embed. Rotate here if the project changes.
    private static let supabaseProjectURL = URL(string: "https://rqhhvuaoksuvbvlypztn.supabase.co")
    private static let supabasePublishableKey = "sb_publishable_uSZDOKvLxbeZnk-6CzoC1w_k2mADwLe"

    /// Local Next.js dev server (`npm run dev`).
    /// NOTE: plain `http://localhost` requires an App Transport Security
    /// exception in the app's Info.plist (see the repo README).
    ///
    /// Live-sync points at the same Supabase project the local backend uses
    /// (local dev shares the dev Supabase project).
    public static let local = TovisConfig(
        // TEMP (device testing 2026-06-30): pointed at the Mac's LAN IP so a
        // physical phone reaches the dev server over Wi-Fi (`localhost` on-device
        // = the phone itself). ⚠️ REVERT to http://localhost:3000/api/v1 before
        // committing — this IP is machine/network-specific.
        baseURL: URL(string: "http://192.168.4.192:3000/api/v1")!,
        supabaseURL: supabaseProjectURL,
        supabaseAnonKey: supabasePublishableKey
    )

    /// Production — the live backend at tovis.app. We target the canonical
    /// `www.` host directly: the apex `tovis.app` 307-redirects to
    /// `www.tovis.app`, and a cross-host redirect can drop the `Authorization`
    /// header on URLSession, so we skip it. Serves the same `/api/v1` surface
    /// against the prod Supabase DB the web app uses, so data is shared
    /// between web and iOS.
    public static let production = TovisConfig(
        baseURL: URL(string: "https://www.tovis.app/api/v1")!,
        supabaseURL: supabaseProjectURL,
        supabaseAnonKey: supabasePublishableKey
    )
}