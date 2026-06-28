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
        baseURL: URL(string: "http://localhost:3000/api/v1")!,
        supabaseURL: supabaseProjectURL,
        supabaseAnonKey: supabasePublishableKey
    )

    /// Production. Replace YOUR-DOMAIN with the real host before shipping.
    public static let production = TovisConfig(
        baseURL: URL(string: "https://YOUR-DOMAIN/api/v1")!,
        supabaseURL: supabaseProjectURL,
        supabaseAnonKey: supabasePublishableKey
    )
}