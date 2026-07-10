import Foundation

/// The client's review of a completed appointment — create / edit / delete the
/// text review (rating + headline + body) and manage its photos (§5 A3-rev 4b).
/// Authenticated; CLIENT-only. Mirrors the web review routes:
///   • POST   /api/v1/client/bookings/{id}/review              — create (create-only;
///                                                                409s if one exists)
///   • PATCH  /api/v1/client/reviews/{id}                      — edit text
///   • DELETE /api/v1/client/reviews/{id}                      — remove (409s if it
///                                                                still carries media)
///   • GET    /api/v1/client/bookings/{id}/review-media-options — session photos to attach
///   • POST   /api/v1/client/uploads                            — presign a fresh upload
///   • POST   /api/v1/client/reviews/{id}/media                 — attach uploaded media
///   • DELETE /api/v1/client/reviews/{id}/media/{mediaId}       — remove one photo
public final class ReviewsService: Sendable {
    private let api: APIClient
    /// Supabase project URL + publishable key — the same public creds the signed
    /// storage PUT uses (nil disables review photo uploads).
    private let supabaseURL: URL?
    private let supabaseKey: String?
    /// Ephemeral (no cookie jar) so the RLS-critical signed PUT stays clean.
    private let uploadSession: URLSession
    private static let idempotencyHeader = "idempotency-key"

    public init(api: APIClient, supabaseURL: URL? = nil, supabaseKey: String? = nil) {
        self.api = api
        self.supabaseURL = supabaseURL
        self.supabaseKey = supabaseKey
        self.uploadSession = URLSession(configuration: .ephemeral)
    }

    /// POST /api/v1/client/bookings/{id}/review — leave a new review. Optionally
    /// attaches existing session photos (`attachedMediaIds`, from
    /// `reviewMediaOptions`) and/or freshly-uploaded photos (`uploadSessionIds`,
    /// from `uploadReviewPhoto`) in the same create call — the only time session
    /// photos can be attached (the web attach route is fresh-uploads only).
    ///
    /// The route requires an idempotency key, so the key carries a body-derived
    /// SORTED-KEYS nonce (via `JSONEncoder.canonical`): a genuine double-tap in
    /// the 60s bucket dedupes to the first response, while an edited submission
    /// (different rating/text/photos) mints a fresh key. A bare encoder's unstable
    /// key order would defeat that dedup — same gotcha as the product-checkout save.
    @discardableResult
    public func submitReview(
        bookingId: String,
        rating: Int,
        headline: String?,
        body: String?,
        attachedMediaIds: [String] = [],
        uploadSessionIds: [String] = [],
        idempotencyKey: String? = nil
    ) async throws -> ClientReview {
        let payload = try JSONEncoder.canonical.encode(
            ClientReviewTextRequest(
                rating: rating,
                headline: Self.normalize(headline),
                body: Self.normalize(body),
                attachedMediaIds: attachedMediaIds.isEmpty ? nil : attachedMediaIds,
                media: uploadSessionIds.isEmpty
                    ? nil
                    : uploadSessionIds.map { ReviewMediaRef(uploadSessionId: $0) }))
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
    /// rejects deletes of reviews that carry media (409).
    public func deleteReview(reviewId: String) async throws {
        try await api.requestVoid("/client/reviews/\(reviewId)", method: .delete)
    }

    // MARK: - Review photos (§5 A3-rev 4b)

    /// GET /api/v1/client/bookings/{id}/review-media-options — the pro's session
    /// photos the client can attach to a NEW review (attaching is the publish-
    /// consent action). Only meaningful before a review exists (the attach route
    /// takes fresh uploads only, not session ids).
    public func reviewMediaOptions(bookingId: String) async throws -> [ReviewMediaOption] {
        let response: ReviewMediaOptionsResponse = try await api.request(
            "/client/bookings/\(bookingId)/review-media-options")
        return response.items
    }

    /// Presign → RLS-critical signed PUT one review photo to media-public, returning
    /// the `uploadSessionId` to hand to `submitReview` (create) or
    /// `attachReviewMedia` (existing review). Reuses the shared `SupabaseSignedUpload`
    /// (never re-roll the signed PUT — the token is the sole authorizer).
    public func uploadReviewPhoto(
        imageData: Data,
        contentType: String = "image/jpeg"
    ) async throws -> String {
        let payload = try JSONEncoder.canonical.encode(
            ReviewUploadInitRequest(
                kind: "REVIEW_PUBLIC", contentType: contentType, size: imageData.count))
        let initData: MediaUploadInit = try await api.request(
            "/client/uploads", method: .post, body: payload)
        try await SupabaseSignedUpload.put(
            session: uploadSession,
            supabaseURL: supabaseURL,
            supabaseKey: supabaseKey,
            data: imageData,
            bucket: initData.bucket,
            path: initData.path,
            token: initData.token,
            contentType: contentType,
            upsert: true)
        return initData.uploadSessionId
    }

    /// POST /api/v1/client/reviews/{id}/media — attach freshly-uploaded photos
    /// (by `uploadSessionId`) to an EXISTING review. No-op for an empty list.
    public func attachReviewMedia(reviewId: String, uploadSessionIds: [String]) async throws {
        guard !uploadSessionIds.isEmpty else { return }
        let payload = try JSONEncoder.canonical.encode(
            ReviewMediaAttachRequest(
                media: uploadSessionIds.map { ReviewMediaRef(uploadSessionId: $0) }))
        try await api.requestVoid(
            "/client/reviews/\(reviewId)/media", method: .post, body: payload)
    }

    /// DELETE /api/v1/client/reviews/{id}/media/{mediaId} — remove one attached
    /// photo. The route 409s if the media is featured in the pro's portfolio/Looks.
    public func removeReviewMedia(reviewId: String, mediaId: String) async throws {
        try await api.requestVoid(
            "/client/reviews/\(reviewId)/media/\(mediaId)", method: .delete)
    }

    /// Trim surrounding whitespace so the nonce is stable and empty input clears
    /// the field server-side ("" → null). The server trims again defensively.
    private static func normalize(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Wire models

/// Request body for creating/editing a review. `headline`/`body` are always
/// present (possibly empty → cleared server-side). `attachedMediaIds` (session
/// photos) + `media` (fresh-upload session ids) are create-only and omitted when
/// empty, so a text-only submit is byte-identical to the 4a payload (stable
/// nonce). Encoded via `JSONEncoder.canonical` so the create path's nonce is
/// byte-stable.
struct ClientReviewTextRequest: Encodable, Sendable {
    let rating: Int
    let headline: String
    let body: String
    var attachedMediaIds: [String]? = nil
    var media: [ReviewMediaRef]? = nil
}

/// A single upload-session reference — the `{ uploadSessionId }` shape both the
/// review create body's `media[]` and the attach route's `media[]` use.
struct ReviewMediaRef: Encodable, Sendable {
    let uploadSessionId: String
}

/// POST /api/v1/client/uploads — presign request for a review photo. `kind` is
/// `REVIEW_PUBLIC` (lands in media-public; attaching is the publish-consent
/// action). No booking/phase — the review it attaches to carries those.
struct ReviewUploadInitRequest: Encodable, Sendable {
    let kind: String
    let contentType: String
    let size: Int
}

/// POST /api/v1/client/reviews/{id}/media — attach body: `{ media: [{uploadSessionId}] }`.
struct ReviewMediaAttachRequest: Encodable, Sendable {
    let media: [ReviewMediaRef]
}

/// GET /api/v1/client/bookings/{id}/review-media-options → `{ items }`.
struct ReviewMediaOptionsResponse: Decodable, Sendable {
    let items: [ReviewMediaOption]
}

/// One candidate session photo the client can attach to a new review. Mirrors the
/// web review-media-options item (`{ id, url, thumbUrl, mediaType, createdAt,
/// phase }`). `phase`/`mediaType` decode leniently so a new server value can't
/// wedge the list.
public struct ReviewMediaOption: Decodable, Sendable, Identifiable {
    public let id: String
    public let url: String
    public let thumbUrl: String?
    public let mediaType: MediaType
    public let createdAt: String
    public let phase: MediaPhase?

    private enum CodingKeys: String, CodingKey {
        case id, url, thumbUrl, mediaType, createdAt, phase
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        thumbUrl = try c.decodeIfPresent(String.self, forKey: .thumbUrl)
        mediaType = (try? c.decode(MediaType.self, forKey: .mediaType)) ?? .image
        createdAt = (try? c.decode(String.self, forKey: .createdAt)) ?? ""
        phase = try? c.decodeIfPresent(MediaPhase.self, forKey: .phase)
    }

    /// True for a VIDEO option (renders a badge tile in the picker).
    public var isVideo: Bool { mediaType == .video }
    /// Best thumbnail URL for the picker tile.
    public var displayThumbUrl: String { thumbUrl ?? url }
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
