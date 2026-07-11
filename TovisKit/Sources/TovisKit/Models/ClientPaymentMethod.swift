import Foundation

/// A saved card on file for the signed-in client — the display metadata the app
/// lists without a Stripe round-trip (never the full PAN). Decoded from
/// `GET /api/v1/client/payment-methods` → `{ ok, paymentMethods: [...] }`.
///
/// Mirrors web `lib/dto/clientPaymentMethods.ts` `ClientPaymentMethodDTO`. The
/// whole card-on-file surface is dark behind the backend
/// `ENABLE_NO_SHOW_PROTECTION` flag — every route 404s while it's off (the prod
/// default), which the UI degrades to a "not available yet" state.
public struct ClientPaymentMethod: Decodable, Sendable, Identifiable {
    public let id: String
    /// Card network, e.g. "visa" | "mastercard". Nil until Stripe details load.
    public let brand: String?
    /// Last four digits of the card. Nil until Stripe details load.
    public let last4: String?
    /// Expiry month 1-12.
    public let expMonth: Int?
    /// Expiry year, four digits.
    public let expYear: Int?
    /// The card charged first for a no-show fee. Exactly one default per client.
    public let isDefault: Bool
    /// ISO-8601 instant the card was saved.
    public let createdAt: String

    public init(
        id: String,
        brand: String?,
        last4: String?,
        expMonth: Int?,
        expYear: Int?,
        isDefault: Bool,
        createdAt: String
    ) {
        self.id = id
        self.brand = brand
        self.last4 = last4
        self.expMonth = expMonth
        self.expYear = expYear
        self.isDefault = isDefault
        self.createdAt = createdAt
    }
}

/// `{ ok, paymentMethods: [...] }` envelope for GET /client/payment-methods.
struct ClientPaymentMethodListResponse: Decodable, Sendable {
    let paymentMethods: [ClientPaymentMethod]
}

/// Response for POST /client/payment-methods/setup-intent — the SetupIntent the
/// client confirms with the Stripe SDK, plus the publishable key to initialize
/// it with. `publishableKey` is the additive field the paired web PR vends (nil
/// on an older server) so the SDK key always matches the backend Stripe mode.
public struct ClientSetupIntent: Decodable, Sendable {
    public let clientSecret: String
    public let setupIntentId: String
    public let customerId: String
    public let publishableKey: String?
}

/// `{ ok, paymentMethod: {...} }` envelope for POST /client/payment-methods.
struct ClientPaymentMethodConfirmResponse: Decodable, Sendable {
    let paymentMethod: ClientPaymentMethod
}
