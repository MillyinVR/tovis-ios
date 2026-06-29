import Foundation

// Wire models for the PRO's payment settings (web Edit payment settings modal).
// Mirrors `paymentSettingsSelect` in `app/api/v1/pro/payment-settings/route.ts`.
// `GET` returns `{ ok, paymentSettings: settings | null }` (null until the pro has
// saved once); `PATCH` upserts and returns the same envelope. Decimal money fields
// serialize as strings (e.g. "20"); `depositPercent` is an int. Inline backend
// shape (decode-only). See docs/PRO-BACKEND-CONTRACTS.md.

/// `GET`/`PATCH /api/v1/pro/payment-settings` → `{ ok, paymentSettings }`.
public struct ProPaymentSettingsResponse: Decodable, Sendable {
    /// `null` until the pro saves payment settings for the first time.
    public let paymentSettings: ProPaymentSettings?
}

public struct ProPaymentTipSuggestion: Codable, Sendable, Equatable {
    public let label: String
    /// Whole-percent value (the route truncates on save). Decoded as Double for
    /// resilience against any legacy non-integer rows.
    public let percent: Double

    public init(label: String, percent: Double) {
        self.label = label
        self.percent = percent
    }
}

public struct ProPaymentSettings: Decodable, Sendable {
    public let collectPaymentAt: String   // "AT_BOOKING" | "AFTER_SERVICE"

    public let depositEnabled: Bool
    public let depositType: String         // "FLAT" | "PERCENT"
    /// Decimal dollars as a string (e.g. "20"), or nil.
    public let depositFlatAmount: String?
    public let depositPercent: Int?
    public let depositScope: String        // "NEW_DISCOVERY_ONLY" | "ALL_NEW_CLIENTS" | "ALL_CLIENTS"

    public let acceptCash: Bool
    public let acceptCardOnFile: Bool
    public let acceptTapToPay: Bool
    public let acceptVenmo: Bool
    public let acceptZelle: Bool
    public let acceptAppleCash: Bool
    public let acceptPaypal: Bool
    public let acceptApplePay: Bool

    public let tipsEnabled: Bool
    public let allowCustomTip: Bool
    public let tipSuggestions: [ProPaymentTipSuggestion]?

    public let venmoHandle: String?
    public let zelleHandle: String?
    public let appleCashHandle: String?
    public let paypalHandle: String?
    public let paymentNote: String?
}

/// PATCH body. The route reads missing fields as their defaults (e.g. an omitted
/// `depositFlatAmount` → null), so optional fields are simply dropped when nil —
/// matching the web modal, which clears off-state handles to empty/null on save.
public struct ProPaymentSettingsUpdate: Encodable, Sendable {
    public let collectPaymentAt: String

    public let depositEnabled: Bool
    public let depositType: String
    public let depositScope: String
    public let depositFlatAmount: String?
    public let depositPercent: String?

    public let acceptCash: Bool
    public let acceptCardOnFile: Bool
    public let acceptTapToPay: Bool
    public let acceptVenmo: Bool
    public let acceptZelle: Bool
    public let acceptAppleCash: Bool
    public let acceptPaypal: Bool
    public let acceptApplePay: Bool

    public let tipsEnabled: Bool
    public let allowCustomTip: Bool
    public let tipSuggestions: [ProPaymentTipSuggestion]

    public let venmoHandle: String?
    public let zelleHandle: String?
    public let appleCashHandle: String?
    public let paypalHandle: String?
    public let paymentNote: String?

    public init(
        collectPaymentAt: String,
        depositEnabled: Bool,
        depositType: String,
        depositScope: String,
        depositFlatAmount: String?,
        depositPercent: String?,
        acceptCash: Bool,
        acceptCardOnFile: Bool,
        acceptTapToPay: Bool,
        acceptVenmo: Bool,
        acceptZelle: Bool,
        acceptAppleCash: Bool,
        acceptPaypal: Bool,
        acceptApplePay: Bool,
        tipsEnabled: Bool,
        allowCustomTip: Bool,
        tipSuggestions: [ProPaymentTipSuggestion],
        venmoHandle: String?,
        zelleHandle: String?,
        appleCashHandle: String?,
        paypalHandle: String?,
        paymentNote: String?
    ) {
        self.collectPaymentAt = collectPaymentAt
        self.depositEnabled = depositEnabled
        self.depositType = depositType
        self.depositScope = depositScope
        self.depositFlatAmount = depositFlatAmount
        self.depositPercent = depositPercent
        self.acceptCash = acceptCash
        self.acceptCardOnFile = acceptCardOnFile
        self.acceptTapToPay = acceptTapToPay
        self.acceptVenmo = acceptVenmo
        self.acceptZelle = acceptZelle
        self.acceptAppleCash = acceptAppleCash
        self.acceptPaypal = acceptPaypal
        self.acceptApplePay = acceptApplePay
        self.tipsEnabled = tipsEnabled
        self.allowCustomTip = allowCustomTip
        self.tipSuggestions = tipSuggestions
        self.venmoHandle = venmoHandle
        self.zelleHandle = zelleHandle
        self.appleCashHandle = appleCashHandle
        self.paypalHandle = paypalHandle
        self.paymentNote = paymentNote
    }
}
