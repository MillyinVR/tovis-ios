import Foundation

// Wire models for PRO session media (before/after photos).
// Mirrors `tovis-app/lib/dto/mediaAttach.ts` (MediaUploadInitDTO,
// ProBookingMediaItemDTO, the list/create envelopes) + the routes
// `app/api/v1/pro/uploads` and `app/api/v1/pro/bookings/[id]/media`.

/// The session media phase. Matches Prisma `MediaPhase` (the camera uses
/// BEFORE/AFTER; OTHER exists for misc session shots).
public enum MediaPhase: String, Codable, Sendable {
    case before = "BEFORE"
    case after = "AFTER"
    case other = "OTHER"
}

/// Media kind. Photos are IMAGE; matches Prisma `MediaType`.
public enum MediaType: String, Codable, Sendable {
    case image = "IMAGE"
    case video = "VIDEO"
}

/// `POST /api/v1/pro/uploads` — request body for a booking-scoped session upload.
/// `kind` is `CONSULT_PRIVATE` (the kind that produces the `bookings/<id>/<phase>/`
/// path in the media-private bucket — see the uploads route's path resolver).
struct MediaUploadInitRequest: Encodable, Sendable {
    let kind: String
    let bookingId: String
    let phase: String
    let contentType: String
    let size: Int
}

/// `POST /api/v1/pro/uploads` — request body for a public, stable-path upload
/// (`AVATAR_PUBLIC` / `SERVICE_IMAGE_PUBLIC`). No booking/phase; `serviceId` only
/// for service images. Produces a `publicUrl` (no UploadSession).
struct PublicUploadInitRequest: Encodable, Sendable {
    let kind: String
    let contentType: String
    let size: Int
    let serviceId: String?
}

/// `POST /api/v1/pro/uploads` → presign for a public, stable-path upload. The
/// route returns `uploadSessionId: null` for these kinds, so it isn't modeled.
public struct PublicUploadInit: Decodable, Sendable {
    public let bucket: String
    public let path: String
    public let token: String
    public let publicUrl: String?
    public let cacheBuster: Int?
}

/// `POST /api/v1/pro/uploads` → `MediaUploadInitDTO`. The presigned target +
/// the upload-session handle the confirm step keys on.
public struct MediaUploadInit: Decodable, Sendable {
    public let bucket: String
    public let path: String
    public let token: String
    public let signedUrl: String?
    public let publicUrl: String?
    public let isPublic: Bool
    public let uploadSessionId: String
}

/// A normalized subject focal point (camera C6) — the (x, y) of the face in the
/// EXIF-corrected upright image, both in [0,1] from the TOP-LEFT origin. Sent on
/// the media confirm so the Looks feed's full-screen cover-crop centers on the
/// subject instead of the blind geometric center. Mirrors the web
/// `resolveFocalPoint` (`lib/media/focalPoint.ts`): a non-finite or out-of-[0,1]
/// coordinate is rejected, so a bad focal degrades to nil (center) rather than
/// shipping garbage the render would clamp anyway.
public struct MediaFocalPoint: Sendable, Equatable {
    public let x: Double
    public let y: Double

    /// Validated init — nil unless BOTH coordinates are finite and within [0,1].
    public init?(x: Double?, y: Double?) {
        guard let x, let y, x.isFinite, y.isFinite,
              (0.0...1.0).contains(x), (0.0...1.0).contains(y) else { return nil }
        self.x = x
        self.y = y
    }
}

/// `POST /api/v1/pro/bookings/{id}/media` — confirm body. The server resolves the
/// storage path from the upload session, so we only send the session + tags.
/// `thumbUploadSessionId` is a second presigned session carrying a poster frame
/// (video rows get a real thumbnail); nil is omitted, which older servers ignore.
/// `focalX`/`focalY` are the normalized subject focal (camera C6) — same nil-is-
/// omitted contract, so a faceless shot (or a server that predates the field)
/// stays center.
struct MediaConfirmRequest: Encodable, Sendable {
    let uploadSessionId: String
    let thumbUploadSessionId: String?
    let phase: String
    let mediaType: String
    let caption: String?
    let focalX: Double?
    let focalY: Double?
}

/// A session media row (`ProBookingMediaItemDTO`). Private bucket → `url`/`thumbUrl`
/// are short-lived signed URLs; `renderUrl`/`renderThumbUrl` mirror them for display.
public struct ProBookingMediaItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let mediaType: MediaType
    /// Raw visibility string (e.g. "PRIVATE"). Kept as String for forward-compat.
    public let visibility: String
    public let phase: MediaPhase
    public let caption: String?
    public let createdAt: String
    public let reviewId: String?
    /// Whether this shot can be published to the public Looks feed.
    public let isEligibleForLooks: Bool
    /// Whether it's already featured in the pro's portfolio (drives the
    /// comparison-slider → portfolio-publish flow in a later phase).
    public let isFeaturedInPortfolio: Bool
    public let url: String?
    public let thumbUrl: String?
    public let renderUrl: String?
    public let renderThumbUrl: String?

    /// Best display URL (full render → render thumb → url → thumb).
    public var displayUrl: String? { renderUrl ?? url ?? renderThumbUrl ?? thumbUrl }
    /// Best thumbnail URL.
    public var displayThumbUrl: String? { renderThumbUrl ?? thumbUrl ?? renderUrl ?? url }
}

/// `GET /api/v1/pro/bookings/{id}/media` → list envelope. `clientUseConsent` is
/// booking-scoped (from `Booking.mediaUseConsentAt`): true when the client
/// granted media-use consent, unlocking the pro's public-share action for the
/// whole session's media (alongside review-promotion — see the web
/// `publicShareGuard`). Decode tolerates its absence (defaults false) so it
/// still decodes against a server that predates the field.
public struct ProBookingMediaListResponse: Decodable, Sendable {
    public let items: [ProBookingMediaItem]
    public let clientUseConsent: Bool

    enum CodingKeys: String, CodingKey {
        case items
        case clientUseConsent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([ProBookingMediaItem].self, forKey: .items)
        clientUseConsent =
            try container.decodeIfPresent(Bool.self, forKey: .clientUseConsent) ?? false
    }
}

/// `POST /api/v1/pro/bookings/{id}/media` → create envelope.
struct ProBookingMediaCreateResponse: Decodable, Sendable {
    let item: ProBookingMediaItem
}
