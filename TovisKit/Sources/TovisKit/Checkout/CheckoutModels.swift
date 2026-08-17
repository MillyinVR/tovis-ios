import Foundation

// Wire models for the booking → pay leg. Mirrors lib/dto/checkout.ts. The app
// reads `stripeCheckout.url` (the hosted Stripe Checkout page), opens it in an
// in-app browser, and is handed back via the `tovis://checkout/return` scheme
// (the backend mints that return URL when we send the native-return header).
// Only the rendered subset is modeled; unknown keys are ignored.

/// The created hosted Checkout session. `url` is null when Stripe omits it.
///
/// 🔴 `sessionId` is OPTIONAL, and that is load-bearing. The final-bill route
/// returns `sessionId: null` when a paid deposit already covers the whole total
/// — there is no charge, so there is no session (web K10-A). As a non-optional
/// `String` under synthesized decoding, that null THREW, and the throw surfaced
/// to the client as "Couldn't start checkout. Please try again." on a booking
/// the server had already settled as PAID. The deposit route always sends an id;
/// leniency here costs it nothing and is the same non-throwing-decode rule
/// `ProPaymentBadge` / `ProRelationshipBadge` / `ProServiceSwatch` follow.
public struct StripeCheckoutSession: Decodable, Sendable {
    public let sessionId: String?
    public let url: String?
}

// MARK: - POST /client/bookings/{id}/checkout/stripe-session

/// Request body for the post-service card checkout. `tipAmount` is an optional
/// decimal string (matching the wire's string-money convention); nil omits it.
///
/// `applyCreatorCredit` is sent on EVERY attempt, `false` included: the server
/// treats a `false` as a RELEASE of any balance a previous attempt was holding
/// against this booking, so omitting it when the client turns the toggle back
/// off would leave their own credit locked up until a sweep expires it.
struct CheckoutStripeSessionRequest: Encodable, Sendable {
    let tipAmount: String?
    let applyCreatorCredit: Bool
}

struct CheckoutStripeSessionResponse: Decodable, Sendable {
    let stripeCheckout: StripeCheckoutSession
    /// True when a paid deposit covered the entire bill: checkout is already
    /// PAID, no session exists, and the client owes nothing. OPTIONAL because a
    /// pre-K10-A server sends neither this nor `depositCreditCents` — an absent
    /// field must decode fine and read as "not settled", which is exactly what
    /// that older server means.
    let settledByDeposit: Bool?
    /// True when the client's own platform CREDIT closed the remaining balance.
    /// Distinct from `settledByDeposit`: they are different money from different
    /// funders, and telling a client their deposit covered a bill they actually
    /// spent credit on is the wrong thing to say about where their money went.
    let settledByCredit: Bool?
    /// Deposit money credited against this bill, in cents (0 when none).
    let depositCreditCents: Int?
    /// Platform credit applied to this bill, in cents (0 when none).
    let creatorCreditCents: Int?
}

/// What starting the final-bill checkout actually produced. An enum rather than
/// a session with nil fields, so a caller cannot try to open a checkout page
/// that does not exist — the device-side mirror of the web write boundary's
/// `STRIPE_SESSION` / `SETTLED_NOTHING_DUE` union.
public enum ClientCheckoutStart: Sendable {
    /// Open `session.url` in the in-app browser.
    case session(StripeCheckoutSession)
    /// Nothing to pay — the deposit covered it and the booking is already PAID.
    case settledByDeposit(creditCents: Int?)
    /// Nothing to pay — the client's credit closed the bill and it is now PAID.
    case settledByCredit(creditCents: Int?)
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

// MARK: - POST /client/bookings/{id}/checkout/products (product selection)

/// One recommendation line to persist to the booking checkout. Mirrors the web
/// submit body's `items[]`. The server validates the `recommendationId` +
/// `productId` belong to this booking's SENT aftercare and re-prices from the
/// catalog, so the client only sends the identity + quantity.
public struct CheckoutProductLineInput: Encodable, Sendable, Equatable {
    public let recommendationId: String
    public let productId: String
    public let quantity: Int

    public init(recommendationId: String, productId: String, quantity: Int) {
        self.recommendationId = recommendationId
        self.productId = productId
        self.quantity = quantity
    }
}

/// Request body for the product-selection save: `{ items: [...] }`. An empty
/// `items` clears the booking's checkout-product selection.
struct CheckoutProductsRequest: Encodable, Sendable {
    let items: [CheckoutProductLineInput]
}

/// The echoed booking + priced selection after saving checkout products. Mirrors
/// the web route's `buildCheckoutProductsResponseBody`; only the fields the app
/// reflects are modeled (unknown keys, incl. `meta`, are ignored).
public struct ClientCheckoutProductsResponse: Decodable, Sendable {
    public struct Booking: Decodable, Sendable {
        public let id: String
        public let checkoutStatus: String?
        public let serviceSubtotalSnapshot: String?
        public let productSubtotalSnapshot: String?
        public let subtotalSnapshot: String?
        public let tipAmount: String?
        public let taxAmount: String?
        public let discountAmount: String?
        public let totalAmount: String?
        public let paymentAuthorizedAt: String?
        public let paymentCollectedAt: String?
    }

    /// One priced line the server persisted (unit price + line total snapshot).
    public struct SelectedProduct: Decodable, Sendable, Identifiable {
        public let recommendationId: String
        public let productId: String
        public let quantity: Int
        public let unitPrice: String
        public let lineTotal: String

        public var id: String { recommendationId }
    }

    public let booking: Booking
    public let selectedProducts: [SelectedProduct]
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
