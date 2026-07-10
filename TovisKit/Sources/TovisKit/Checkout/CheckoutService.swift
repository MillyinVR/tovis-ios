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
        let payload = try JSONEncoder().encode(
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
        let payload = try JSONEncoder().encode(
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
