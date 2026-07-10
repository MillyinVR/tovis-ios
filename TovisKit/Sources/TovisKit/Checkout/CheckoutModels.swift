import Foundation

// Wire models for the booking → pay leg. Mirrors lib/dto/checkout.ts. The app
// reads `stripeCheckout.url` (the hosted Stripe Checkout page), opens it in an
// in-app browser, and is handed back via the `tovis://checkout/return` scheme
// (the backend mints that return URL when we send the native-return header).
// Only the rendered subset is modeled; unknown keys are ignored.

/// The created hosted Checkout session. `url` is null when Stripe omits it.
public struct StripeCheckoutSession: Decodable, Sendable {
    public let sessionId: String
    public let url: String?
}

// MARK: - POST /client/bookings/{id}/checkout/stripe-session

/// Request body for the post-service card checkout. `tipAmount` is an optional
/// decimal string (matching the wire's string-money convention); nil omits it.
struct CheckoutStripeSessionRequest: Encodable, Sendable {
    let tipAmount: String?
}

struct CheckoutStripeSessionResponse: Decodable, Sendable {
    let stripeCheckout: StripeCheckoutSession
}

// MARK: - POST /client/bookings/{id}/checkout (non-card confirm / save tip)

/// Request body for the non-card client checkout. Mirrors the web
/// `ClientCheckoutCard` submit: `confirmPayment: true` confirms a payment
/// (unverifiable off-platform → AWAITING_CONFIRMATION, card-on-file / tap-to-pay
/// → PAID); `false` just saves the tip/method. `tipAmount` is a decimal string;
/// nil optionals are omitted so the server reads them as "unchanged".
struct ClientCheckoutConfirmRequest: Encodable, Sendable {
    let tipAmount: String?
    let selectedPaymentMethod: String?
    let confirmPayment: Bool
}

/// The echoed booking after a non-card checkout. Mirrors
/// `ClientCheckoutConfirmResponseDTO`; only the fields the app reflects are
/// modeled (unknown keys, incl. `meta`, are ignored).
public struct ClientCheckoutConfirmResponse: Decodable, Sendable {
    public struct Booking: Decodable, Sendable {
        public let id: String
        public let checkoutStatus: String?
        public let selectedPaymentMethod: String?
        public let tipAmount: String?
        public let totalAmount: String?
        public let paymentAuthorizedAt: String?
        public let paymentCollectedAt: String?
    }

    public let booking: Booking
}

// MARK: - POST /client/bookings/{id}/deposit/stripe-session

/// Up-front discovery deposit + one-time platform fee breakdown (minor units).
public struct DepositBreakdown: Decodable, Sendable {
    public let depositCents: Int
    public let feeCents: Int
    public let totalCents: Int
    public let currency: String
}

public struct DepositStripeSessionResponse: Decodable, Sendable {
    public let deposit: DepositBreakdown
    public let stripeCheckout: StripeCheckoutSession
}
