import Foundation

/// A one-time URL that signs this same pro into a WEB browser and drops them on
/// an allowlisted `/pro/*` page.
///
/// Why this exists: tapping out to the site opens `SFSafariViewController`,
/// which shares SAFARI's cookie jar — it has no idea the app is signed in. A pro
/// who is not separately signed in on Safari would hit the login wall on a
/// button that promised to take them to their plan.
///
/// ⚠️ Treat `url` as a CREDENTIAL, not as a link:
///   • single-use — opening it burns it, and a second open lands on `/login`
///   • expires within 60 seconds of issuance (`expiresAt`)
///   • never persist it, never log it, never put it on a pasteboard or in a
///     share sheet. Request one at the moment of the tap and open it at once.
public struct SessionHandoff: Decodable, Sendable {
    /// The absolute exchange URL to open in a browser. Built server-side, so the
    /// app never assembles an auth URL itself.
    public let url: URL
    /// Where the browser lands after the hand-off, e.g. `/pro/membership`.
    public let redirectPath: String
    /// ISO-8601 instant the token dies (≤60s out).
    public let expiresAt: String
}
