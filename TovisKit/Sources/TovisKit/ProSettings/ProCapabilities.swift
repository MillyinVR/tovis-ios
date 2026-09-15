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
    /// `ENABLE_CLIENT_TECHNICAL_RECORD` **or** this pro being on the dogfood
    /// allowlist — the whole technical-record surface, including the pro's
    /// consent form library.
    ///
    /// 🔴 Per-pro, unlike its neighbours: the server resolves it from the ACTING
    /// pro's id, not the env alone. So it must be re-read after a workspace
    /// switch rather than carried across one.
    public let clientTechnicalRecord: Bool

    /// 🔴 What an app that could not read the wire must assume. Hiding a live
    /// feature is recoverable — the pro sees the row on the next load. Offering
    /// a dead one is not: it walks them into the dead end this type exists to
    /// remove. Never default these to `true`.
    public static let none = ProCapabilities(
        noShowFees: false,
        importFromAnotherApp: false,
        clientTechnicalRecord: false
    )

    public init(
        noShowFees: Bool,
        importFromAnotherApp: Bool,
        clientTechnicalRecord: Bool = false
    ) {
        self.noShowFees = noShowFees
        self.importFromAnotherApp = importFromAnotherApp
        self.clientTechnicalRecord = clientTechnicalRecord
    }

    private enum CodingKeys: String, CodingKey {
        case noShowFees, importFromAnotherApp, clientTechnicalRecord
    }

    /// 🔴 Hand-written for one reason: `clientTechnicalRecord` is ABSENT on any
    /// server older than the PR that added it, and a synthesized decode would
    /// throw on the whole payload there. The caller reads that throw as "no
    /// capabilities" and hides the no-show and import rows too — a new field
    /// taking two working rows down with it.
    ///
    /// Absent therefore degrades to `false`, which is the same answer the
    /// doctrine above already demands of an unreadable wire: the consent-form
    /// row simply does not appear until web deploys.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        noShowFees = try container.decode(Bool.self, forKey: .noShowFees)
        importFromAnotherApp = try container.decode(
            Bool.self, forKey: .importFromAnotherApp
        )
        clientTechnicalRecord =
            try container.decodeIfPresent(Bool.self, forKey: .clientTechnicalRecord)
            ?? false
    }
}

struct ProCapabilitiesResponse: Decodable, Sendable {
    let capabilities: ProCapabilities
}
