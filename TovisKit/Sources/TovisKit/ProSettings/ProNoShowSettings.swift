import Foundation

/// A pro's account-level no-show / late-cancel fee policy (web
/// `GET/PUT /pro/no-show-settings`, Phase 2 revenue protection). Dark unless
/// `ENABLE_NO_SHOW_PROTECTION` is on — the endpoints 404 while the flag is off,
/// so the iOS screen shows a "not available yet" state until it flips.
public struct ProNoShowSettings: Decodable, Sendable {
    /// Master opt-in. While false the pro never charges a fee.
    public let enabled: Bool
    /// `FLAT` (a dollar amount) or `PERCENT` (of the booking total).
    public let feeType: String
    /// Flat fee as a 2dp money string (e.g. "25.00"), or nil.
    public let feeFlatAmount: String?
    /// Percent of the booking total (1–100), or nil.
    public let feePercent: Int?
    /// Hours before start inside which a client cancel is a billable late cancel.
    public let cancelWindowHours: Int
    public let chargeNoShow: Bool
    public let chargeLateCancel: Bool
}

struct ProNoShowSettingsResponse: Decodable, Sendable {
    let settings: ProNoShowSettings
}

/// PUT body. Optionals omitted when nil — the server reads absent as null.
public struct ProNoShowSettingsUpdate: Encodable, Sendable {
    public let enabled: Bool
    public let feeType: String
    public let feeFlatAmount: String?
    public let feePercent: Int?
    public let cancelWindowHours: Int
    public let chargeNoShow: Bool
    public let chargeLateCancel: Bool

    public init(
        enabled: Bool, feeType: String, feeFlatAmount: String?, feePercent: Int?,
        cancelWindowHours: Int, chargeNoShow: Bool, chargeLateCancel: Bool
    ) {
        self.enabled = enabled
        self.feeType = feeType
        self.feeFlatAmount = feeFlatAmount
        self.feePercent = feePercent
        self.cancelWindowHours = cancelWindowHours
        self.chargeNoShow = chargeNoShow
        self.chargeLateCancel = chargeLateCancel
    }
}
