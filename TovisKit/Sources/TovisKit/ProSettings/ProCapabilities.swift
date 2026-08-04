import Foundation

/// Which flag-held pro features are live on the server this app is talking to
/// (web `GET /api/v1/pro/capabilities`).
///
/// Web reads these env flags server-side and simply omits the surface when one
/// is off — the no-show section of its payment-settings modal takes a
/// `noShowFeatureEnabled` prop, and `ProHeader` drops the Import tab entirely.
/// Native had no equivalent: the only way to learn a flag was to open the
/// feature and read a 404, which is exactly why both rows dead-ended on a
/// "Coming soon" screen. This type is that server-side answer, on the wire.
public struct ProCapabilities: Decodable, Sendable, Equatable {
    /// `ENABLE_NO_SHOW_PROTECTION` — no-show / late-cancel fee settings, the
    /// client card-on-file rail, and real fee charging.
    public let noShowFees: Bool
    /// `ENABLE_PRO_MIGRATION` — the guided import wizard (services, clients,
    /// calendar) for a pro coming from another booking app.
    public let importFromAnotherApp: Bool

    /// 🔴 What an app that could not read the wire must assume. Hiding a live
    /// feature is recoverable — the pro sees the row on the next load. Offering
    /// a dead one is not: it walks them into the dead end this type exists to
    /// remove. Never default these to `true`.
    public static let none = ProCapabilities(noShowFees: false, importFromAnotherApp: false)

    public init(noShowFees: Bool, importFromAnotherApp: Bool) {
        self.noShowFees = noShowFees
        self.importFromAnotherApp = importFromAnotherApp
    }
}

struct ProCapabilitiesResponse: Decodable, Sendable {
    let capabilities: ProCapabilities
}
