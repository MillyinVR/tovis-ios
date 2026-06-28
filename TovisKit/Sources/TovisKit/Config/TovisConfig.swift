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

    /// Local Next.js dev server (`npm run dev`).
    /// NOTE: plain `http://localhost` requires an App Transport Security
    /// exception in the app's Info.plist (see the repo README).
    ///
    /// For live-sync in dev, set supabaseURL/anonKey to the SAME Supabase
    /// project the local backend uses (the public URL + anon key).
    public static let local = TovisConfig(
        baseURL: URL(string: "http://localhost:3000/api/v1")!,
        supabaseURL: nil,        // e.g. URL(string: "https://<ref>.supabase.co")
        supabaseAnonKey: nil     // the project's anon/publishable key
    )

    /// Production. Replace YOUR-DOMAIN with the real host before shipping, and
    /// set the prod Supabase URL + anon key to enable live-sync.
    public static let production = TovisConfig(
        baseURL: URL(string: "https://YOUR-DOMAIN/api/v1")!,
        supabaseURL: nil,
        supabaseAnonKey: nil
    )
}