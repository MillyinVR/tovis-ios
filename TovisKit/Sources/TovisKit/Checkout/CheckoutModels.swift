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
