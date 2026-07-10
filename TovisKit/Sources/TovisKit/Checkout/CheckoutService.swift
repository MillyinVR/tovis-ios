import Foundation

/// The booking → pay leg. Creates a hosted Stripe Checkout session (post-service
/// checkout or the up-front discovery deposit) and returns the hosted `url` the
/// app opens in an in-app browser. We send the native-return header so the
/// backend points Stripe's success/cancel redirect at the public bounce page,
/// which hands control back to the app via the `tovis://checkout/return` scheme.
/// Authenticated (bearer token; client only).
public final class CheckoutService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// Header that tells the backend to mint a `tovis://` deep-link return URL
    /// instead of the web `/client/bookings/{id}` return. Must match
    /// `NATIVE_RETURN_HEADER` in tovis-app lib/checkout/nativeReturn.ts.
    private static let nativeReturnHeader = "x-tovis-return-target"
    private static let idempotencyHeader = "idempotency-key"

    /// POST /api/v1/client/bookings/{id}/checkout/stripe-session — post-service
    /// card checkout (optional tip). Returns the hosted Stripe Checkout session.
    public func createCheckoutSession(
        bookingId: String,
        tipAmount: String? = nil,
        idempotencyKey: String? = nil
    ) async throws -> StripeCheckoutSession {
        let payload = try JSONEncoder.canonical.encode(
            CheckoutStripeSessionRequest(tipAmount: tipAmount)
        )
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "checkout", entityId: bookingId, action: "stripe-session",
            nonce: idempotencyNonce(payload))
        let response: CheckoutStripeSessionResponse = try await api.request(
            "/client/bookings/\(bookingId)/checkout/stripe-session",
            method: .post,
            body: payload,
            headers: [
                Self.idempotencyHeader: key,
                Self.nativeReturnHeader: "native",
            ]
        )
        return response.stripeCheckout
    }

    /// POST /api/v1/client/bookings/{id}/checkout — confirm a NON-card payment
    /// (cash / Venmo / Zelle / Apple Cash / card-on-file / tap-to-pay) or just save
    /// the tip. Card (`STRIPE_CARD`) must go through `createCheckoutSession` — the
    /// route rejects it here. Unverifiable off-platform methods land in
    /// AWAITING_CONFIRMATION; card-on-file / tap-to-pay close out as PAID.
    ///
    /// - `confirmPayment: true`  → confirm the payment (terminal). The idempotency
    ///   key is action-only (no nonce) so an identical re-submit can never charge
    ///   twice — mirrors the web contract.
    /// - `confirmPayment: false` → save the tip/method. The key carries a
    ///   tip+method nonce so a changed save goes through while a double-tap dedupes.
    public func confirmCheckout(
        bookingId: String,
        tipAmount: String?,
        selectedPaymentMethod: String?,
        confirmPayment: Bool,
        idempotencyKey: String? = nil
    ) async throws -> ClientCheckoutConfirmResponse {
        let payload = try JSONEncoder.canonical.encode(
            ClientCheckoutConfirmRequest(
                tipAmount: tipAmount,
                selectedPaymentMethod: selectedPaymentMethod,
                confirmPayment: confirmPayment
            )
        )
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "client-checkout",
            entityId: bookingId,
            action: confirmPayment ? "confirm-payment" : "save-checkout",
            nonce: confirmPayment ? "" : "\(tipAmount ?? "")|\(selectedPaymentMethod ?? "")"
        )
        return try await api.request(
            "/client/bookings/\(bookingId)/checkout",
            method: .post,
            body: payload,
            headers: [
                Self.idempotencyHeader: key,
                Self.nativeReturnHeader: "native",
            ]
        )
    }

    /// POST /api/v1/client/bookings/{id}/checkout/products — save the client's
    /// pro-recommended product selection onto the booking checkout (adds internal
    /// recommendations as line items; an empty `items` clears the selection).
    /// Returns the re-rolled booking totals + the priced lines the server kept.
    ///
    /// The selection is iterative (adjust quantities → save → adjust → save), so
    /// the idempotency key carries a body-derived nonce over the lines: a changed
    /// selection gets a fresh key while a true double-tap in the 60s bucket still
    /// dedupes — mirrors web `buildClientIdempotencyKey({ nonce: JSON(lines) })`.
    public func saveCheckoutProducts(
        bookingId: String,
        items: [CheckoutProductLineInput],
        idempotencyKey: String? = nil
    ) async throws -> ClientCheckoutProductsResponse {
        // The body encodes through `JSONEncoder.canonical` (sorted keys), so the
        // same serialized bytes drive both the wire body and the nonce — an
        // identical selection hashes identically across taps, while a changed
        // selection shifts the nonce. (A bare encoder's unstable key order would
        // mint a fresh key on a re-tap and defeat the dedup.)
        let payload = try JSONEncoder.canonical.encode(CheckoutProductsRequest(items: items))
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "client-checkout-products",
            entityId: bookingId,
            action: "save-selection",
            nonce: idempotencyNonce(payload)
        )
        return try await api.request(
            "/client/bookings/\(bookingId)/checkout/products",
            method: .post,
            body: payload,
            headers: [Self.idempotencyHeader: key]
        )
    }

    /// POST /api/v1/client/bookings/{id}/deposit/stripe-session — the new-client
    /// discovery deposit + one-time platform fee. Returns the hosted session.
    public func createDepositSession(
        bookingId: String,
        idempotencyKey: String? = nil
    ) async throws -> DepositStripeSessionResponse {
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "checkout", entityId: bookingId, action: "deposit-session")
        return try await api.request(
            "/client/bookings/\(bookingId)/deposit/stripe-session",
            method: .post,
            body: nil,
            headers: [
                Self.idempotencyHeader: key,
                Self.nativeReturnHeader: "native",
            ]
        )
    }
}
