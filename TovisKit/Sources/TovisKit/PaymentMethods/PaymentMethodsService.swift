import Foundation

/// Client card-on-file — the saved cards a client keeps so a no-show fee can be
/// charged off-session. Backs the native Payment methods settings screen, a port
/// of web `app/client/(gated)/settings/ClientPaymentMethodsSettings.tsx`.
///
/// Add-card runs a Stripe SetupIntent the app confirms with the Stripe SDK, then
/// persists the confirmed card here (the server verifies the SetupIntent belongs
/// to this client and succeeded). Listing reads local display metadata — no
/// Stripe round-trip. There is no set-default action: the newest card is the
/// default, and removing the default promotes the next-newest server-side.
///
/// The whole surface is dark behind the backend `ENABLE_NO_SHOW_PROTECTION`
/// flag: every route 404s while it's off (the prod default). Callers should
/// degrade a 404 to a "not available yet" state rather than surface an error.
public final class PaymentMethodsService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/client/payment-methods → the client's saved cards, default
    /// first then newest.
    public func list() async throws -> [ClientPaymentMethod] {
        let response: ClientPaymentMethodListResponse = try await api.request("/client/payment-methods")
        return response.paymentMethods
    }

    /// POST /api/v1/client/payment-methods/setup-intent (no body) → the
    /// SetupIntent client secret + id to confirm with the Stripe SDK, plus the
    /// publishable key to initialize it with.
    public func createSetupIntent() async throws -> ClientSetupIntent {
        try await api.request("/client/payment-methods/setup-intent", method: .post)
    }

    /// POST /api/v1/client/payment-methods { setupIntentId } → persist the card
    /// the client just confirmed with the SDK and make it the default. No
    /// idempotency key — the server upserts on the Stripe PaymentMethod id, so a
    /// re-confirm updates rather than duplicates.
    @discardableResult
    public func confirmCard(setupIntentId: String) async throws -> ClientPaymentMethod {
        let payload = try JSONEncoder.canonical.encode(
            ClientConfirmCardRequest(setupIntentId: setupIntentId))
        let response: ClientPaymentMethodConfirmResponse = try await api.request(
            "/client/payment-methods", method: .post, body: payload)
        return response.paymentMethod
    }

    /// DELETE /api/v1/client/payment-methods/{id} — remove a saved card
    /// (ownership-scoped; detaches from Stripe; promotes the next-newest to
    /// default if this was the default).
    public func remove(id: String) async throws {
        try await api.requestVoid("/client/payment-methods/\(id)", method: .delete)
    }
}

/// POST /api/v1/client/payment-methods body — the SetupIntent the client just
/// confirmed with the Stripe SDK.
struct ClientConfirmCardRequest: Encodable, Sendable {
    let setupIntentId: String
}
