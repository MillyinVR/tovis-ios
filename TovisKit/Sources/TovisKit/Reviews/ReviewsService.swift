import Foundation

/// The client's review of a completed appointment — create / edit / delete the
/// text review (rating + headline + body). Media attachments are a later pass
/// (§5 A3-rev 4b). Authenticated; CLIENT-only. Mirrors the web review routes:
///   • POST   /api/v1/client/bookings/{id}/review   — create (create-only; 409s
///                                                     if a review already exists)
///   • PATCH  /api/v1/client/reviews/{id}           — edit an existing review
///   • DELETE /api/v1/client/reviews/{id}           — remove it (409s if it has
///                                                     media; text reviews have none)
public final class ReviewsService: Sendable {
    private let api: APIClient
    private static let idempotencyHeader = "idempotency-key"

    public init(api: APIClient) {
        self.api = api
    }

    /// POST /api/v1/client/bookings/{id}/review — leave a new text review.
    ///
    /// The route requires an idempotency key, so the key carries a body-derived
    /// SORTED-KEYS nonce (via `JSONEncoder.canonical`): a genuine double-tap in
    /// the 60s bucket dedupes to the first response, while an edited submission
    /// (different rating/text) mints a fresh key. A bare encoder's unstable key
    /// order would defeat that dedup — same gotcha as the product-checkout save.
    @discardableResult
    public func submitReview(
        bookingId: String,
        rating: Int,
        headline: String?,
        body: String?,
        idempotencyKey: String? = nil
    ) async throws -> ClientReview {
        let payload = try JSONEncoder.canonical.encode(
            ClientReviewTextRequest(
                rating: rating,
                headline: Self.normalize(headline),
                body: Self.normalize(body)))
        let key = idempotencyKey ?? buildClientIdempotencyKey(
            scope: "client-review", entityId: bookingId, action: "create",
            nonce: idempotencyNonce(payload))
        let response: ClientReviewResponse = try await api.request(
            "/client/bookings/\(bookingId)/review",
            method: .post,
            body: payload,
            headers: [Self.idempotencyHeader: key])
        return response.review
    }

    /// PATCH /api/v1/client/reviews/{id} — edit an existing review's text. We
    /// always send all three fields; an empty headline/body is normalized to
    /// null server-side (cleared), matching the create path. The route is
    /// naturally idempotent (a repeated PATCH sets the same values), so no key.
    @discardableResult
    public func updateReview(
        reviewId: String,
        rating: Int,
        headline: String?,
        body: String?
    ) async throws -> ClientReview {
        let payload = try JSONEncoder.canonical.encode(
            ClientReviewTextRequest(
                rating: rating,
                headline: Self.normalize(headline),
                body: Self.normalize(body)))
        let response: ClientReviewResponse = try await api.request(
            "/client/reviews/\(reviewId)",
            method: .patch,
            body: payload)
        return response.review
    }

    /// DELETE /api/v1/client/reviews/{id} — remove the client's review. The route
    /// rejects deletes of reviews that carry media (409); text reviews have none.
    public func deleteReview(reviewId: String) async throws {
        try await api.requestVoid("/client/reviews/\(reviewId)", method: .delete)
    }

    /// Trim surrounding whitespace so the nonce is stable and empty input clears
    /// the field server-side ("" → null). The server trims again defensively.
    private static func normalize(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Wire models

/// Request body for creating/editing a text review. `headline`/`body` are always
/// present (possibly empty → cleared server-side); encoded via
/// `JSONEncoder.canonical` so the create path's nonce is byte-stable.
struct ClientReviewTextRequest: Encodable, Sendable {
    let rating: Int
    let headline: String
    let body: String
}

/// The `{ ok, review: { … } }` envelope both create + edit return. Unknown keys
/// (incl. `mediaAssets`, which 4a ignores) are dropped.
struct ClientReviewResponse: Decodable, Sendable {
    let review: ClientReview
}

/// The persisted review's text slice (media is A3-rev 4b). `rating` is optional
/// only for decode-safety; the server always sends a 1–5 value on success.
public struct ClientReview: Decodable, Sendable, Identifiable {
    public let id: String
    public let rating: Int?
    public let headline: String?
    public let body: String?

    public init(id: String, rating: Int?, headline: String?, body: String?) {
        self.id = id
        self.rating = rating
        self.headline = headline
        self.body = body
    }
}
