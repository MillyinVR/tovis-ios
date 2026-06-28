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
        idempotencyKey: String = UUID().uuidString
    ) async throws -> StripeCheckoutSession {
        let payload = try JSONEncoder().encode(
            CheckoutStripeSessionRequest(tipAmount: tipAmount)
        )
        let response: CheckoutStripeSessionResponse = try await api.request(
            "/client/bookings/\(bookingId)/checkout/stripe-session",
            method: .post,
            body: payload,
            headers: [
                Self.idempotencyHeader: idempotencyKey,
                Self.nativeReturnHeader: "native",
            ]
        )
        return response.stripeCheckout
    }

    /// POST /api/v1/client/bookings/{id}/deposit/stripe-session — the new-client
    /// discovery deposit + one-time platform fee. Returns the hosted session.
    public func createDepositSession(
        bookingId: String,
        idempotencyKey: String = UUID().uuidString
    ) async throws -> DepositStripeSessionResponse {
        try await api.request(
            "/client/bookings/\(bookingId)/deposit/stripe-session",
            method: .post,
            body: nil,
            headers: [
                Self.idempotencyHeader: idempotencyKey,
                Self.nativeReturnHeader: "native",
            ]
        )
    }
}
