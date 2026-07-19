import Foundation

/// Publish a public "look" from a completed appointment — the native counterpart
/// to the web share-your-look flow (`/client/looks/share/[bookingId]` +
/// `ShareLookSheet.tsx`). Authenticated; CLIENT-only.
///
/// The web *prefill* screen is RSC-only (`loadShareLookPage.ts`, no JSON GET), so
/// iOS synthesizes the header (service name / pro / visit date) from the booking
/// detail it already holds and the reuse-candidate photos from
/// `ReviewsService.reviewMediaOptions` (the same `GET /client/bookings/{id}/
/// review-media-options` seam — the pro's session photos, a superset of the web
/// prefill's single before/after). This service ports only the two write seams:
///   • POST /api/v1/client/uploads (kind LOOK_PUBLIC)   — presign a fresh photo
///   • POST /api/v1/client/bookings/{id}/share-look     — publish the look
///
/// Neither route is flag-gated, so this ships live (unlike Payment methods).
public final class ShareLookService: Sendable {
    private let api: APIClient
    /// Supabase project URL + publishable key — the same public creds the signed
    /// storage PUT uses (nil disables fresh look-photo uploads; reuse still works).
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

    /// Presign → RLS-critical signed PUT one fresh look photo to media-public,
    /// returning the `uploadSessionId` to hand to `shareLook` as a `.upload` source.
    ///
    /// Unlike `REVIEW_PUBLIC`, the `LOOK_PUBLIC` kind carries the booking + a
    /// BEFORE/AFTER `phase`, so the server scopes the upload session to this visit
    /// (the share-look route validates the session's `bookingId` before consuming
    /// it). Reuses the shared `SupabaseSignedUpload` — the signed token is the sole
    /// authorizer, and it MUST be PUT (a POST runs as anon and fails RLS).
    public func uploadPhoto(
        bookingId: String,
        phase: MediaPhase,
        imageData: Data,
        contentType: String = "image/jpeg"
    ) async throws -> String {
        let payload = try JSONEncoder.canonical.encode(
            LookUploadInitRequest(
                kind: "LOOK_PUBLIC",
                contentType: contentType,
                size: imageData.count,
                phase: phase.rawValue,
                bookingId: bookingId))
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

    /// POST /api/v1/client/bookings/{id}/share-look — publish a public look from the
    /// visit. `after` is required; `before` optional. Each photo source is either a
    /// reused visit photo (`.reuse`, id from `reviews.reviewMediaOptions`) or a
    /// fresh upload (`.upload`, id from `uploadPhoto`). `isPublic == false` saves it
    /// to the profile without feeding the public discovery feed.
    ///
    /// The route requires an idempotency key, so the key carries a body-derived
    /// SORTED-KEYS nonce (`JSONEncoder.canonical`): a genuine double-tap in the 60s
    /// bucket replays the first look (never a duplicate) while an edited submission
    /// (new name/caption/photo) mints a fresh key — the same contract the review
    /// create path uses. The web sheet mints a random UUID per tap instead and
    /// leans on its submitting flag; the nonce is the stronger guard.
    @discardableResult
    public func shareLook(
        bookingId: String,
        name: String,
        caption: String?,
        isPublic: Bool,
        after: LookPhotoSource,
        before: LookPhotoSource? = nil
    ) async throws -> SharedLook {
        let payload = try JSONEncoder.canonical.encode(
            ShareLookRequest(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                caption: caption?.trimmedOrNil,
                isPublic: isPublic,
                after: after,
                before: before))
        let key = buildClientIdempotencyKey(
            scope: "client-share-look", entityId: bookingId, action: "create",
            nonce: idempotencyNonce(payload))
        let response: ShareLookResponse = try await api.request(
            "/client/bookings/\(bookingId)/share-look",
            method: .post,
            body: payload,
            headers: [Self.idempotencyHeader: key])
        return response.look
    }

}

// MARK: - Wire models

/// A photo for a shared look. Encodes to the web route's discriminated shape —
/// `{ reuseMediaAssetId }` for an existing visit photo or `{ uploadSessionId }`
/// for a fresh upload — matching `parsePhotoSource` in the share-look route (which
/// reads `uploadSessionId` first, else `reuseMediaAssetId`), so exactly one key is
/// ever sent.
public enum LookPhotoSource: Encodable, Sendable, Equatable {
    /// An existing PRO session photo, referenced by its media-asset id (from
    /// `reviews.reviewMediaOptions`). The server copies it into the public bucket.
    case reuse(mediaAssetId: String)
    /// A freshly-uploaded photo, referenced by its upload-session id (from
    /// `uploadPhoto`).
    case upload(sessionId: String)

    private enum CodingKeys: String, CodingKey {
        case reuseMediaAssetId, uploadSessionId
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .reuse(let id):
            try container.encode(id, forKey: .reuseMediaAssetId)
        case .upload(let id):
            try container.encode(id, forKey: .uploadSessionId)
        }
    }
}

/// POST /api/v1/client/bookings/{id}/share-look — publish body. `caption`/`before`
/// omit when nil (synthesized `encodeIfPresent`); `after` is required. Encoded via
/// `JSONEncoder.canonical` for a byte-stable idempotency nonce.
struct ShareLookRequest: Encodable, Sendable {
    let name: String
    let caption: String?
    let isPublic: Bool
    let after: LookPhotoSource
    let before: LookPhotoSource?
}

/// POST /api/v1/client/uploads — presign a fresh LOOK photo. Unlike the review
/// presign (`REVIEW_PUBLIC`, no booking/phase), `LOOK_PUBLIC` carries the booking +
/// BEFORE/AFTER `phase` so the upload session is scoped to this visit.
struct LookUploadInitRequest: Encodable, Sendable {
    let kind: String
    let contentType: String
    let size: Int
    let phase: String
    let bookingId: String
}

/// The `{ ok, look: { … } }` envelope the share-look route returns (201). The `ok`
/// flag and any extra keys are ignored.
struct ShareLookResponse: Decodable, Sendable {
    let look: SharedLook
}

/// The published look's identity slice. `visibility` is kept as a raw String
/// (`PUBLIC` / `UNLISTED`) per the iOS server-driven-labels convention.
public struct SharedLook: Decodable, Sendable, Identifiable {
    public let id: String
    public let visibility: String
    public let serviceId: String
    public let primaryMediaAssetId: String

    public init(id: String, visibility: String, serviceId: String, primaryMediaAssetId: String) {
        self.id = id
        self.visibility = visibility
        self.serviceId = serviceId
        self.primaryMediaAssetId = primaryMediaAssetId
    }
}
