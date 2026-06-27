import Foundation

/// Environment configuration for the API client.
///
/// `baseURL` points at the backend's versioned API root, i.e. it INCLUDES
/// `/api/v1`. Endpoint paths passed to `APIClient` are then relative, e.g.
/// `"/auth/login"`.
public struct TovisConfig: Sendable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Local Next.js dev server (`npm run dev`).
    /// NOTE: plain `http://localhost` requires an App Transport Security
    /// exception in the app's Info.plist (see the repo README).
    public static let local = TovisConfig(
        baseURL: URL(string: "http://localhost:3000/api/v1")!
    )

    /// Production. Replace YOUR-DOMAIN with the real host before shipping.
    public static let production = TovisConfig(
        baseURL: URL(string: "https://YOUR-DOMAIN/api/v1")!
    )
}