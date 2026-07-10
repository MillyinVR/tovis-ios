import Foundation

// Wire models for the PRO media manager — the native counterpart of the web
// `/pro/media` grid + `OwnerMediaMenu` editor (which are RSC-only, so there is a
// dedicated native read API). Mirrors `tovis-app/lib/dto/mediaAttach.ts`
// (ProManagedMediaItemDTO / ProManagedMediaListResponseDTO / ProMediaServiceTagDTO)
// + the routes `GET /api/v1/pro/media` (list) and `PATCH`/`DELETE
// /api/v1/pro/media/{id}` (edit / hard-delete).

/// A `{ serviceId, name }` pair. Serves double duty: a media item's current
/// service tag AND a selectable option in the editor (its `serviceId` is the id
/// sent back in `serviceIds`). Mirrors `ProMediaServiceTagDTO`.
public struct ProMediaServiceTag: Decodable, Sendable, Identifiable, Hashable {
    public let serviceId: String
    public let name: String
    public var id: String { serviceId }
}

/// One item in the pro's own media library (`ProManagedMediaItemDTO`). Carries
/// every field the editor reads/writes. Private-bucket assets carry `url`/
/// `thumbUrl` as `nil` and render via the short-lived `renderUrl`/`renderThumbUrl`.
public struct ProManagedMediaItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let mediaType: MediaType
    /// Raw visibility string ("PUBLIC" / "PRO_CLIENT"). Kept as String for
    /// forward-compat; the editor recomputes it locally from the two flags to
    /// match the server (which always derives it, never trusts a sent value).
    public let visibility: String
    public let caption: String?
    public let createdAt: String
    public let reviewId: String?
    /// Eligible for the public Looks feed.
    public let isEligibleForLooks: Bool
    /// Featured in the pro's public portfolio.
    public let isFeaturedInPortfolio: Bool
    /// The paired "before" asset id when this featured "after" has one; nil when
    /// unpaired. Fed to the pairing editor (a later increment).
    public let beforeAssetId: String?
    public let services: [ProMediaServiceTag]
    public let url: String?
    public let thumbUrl: String?
    public let renderUrl: String?
    public let renderThumbUrl: String?

    /// Best thumbnail URL (render thumb → thumb → full render → url).
    public var displayThumbUrl: String? { renderThumbUrl ?? thumbUrl ?? renderUrl ?? url }
    /// Best full-size URL (full render → url → render thumb → thumb).
    public var displayUrl: String? { renderUrl ?? url ?? renderThumbUrl ?? thumbUrl }
    public var isVideo: Bool { mediaType == .video }
    /// The currently-tagged service ids (the editor seeds its selection from these).
    public var serviceIds: [String] { services.map(\.serviceId) }
}

/// `GET /api/v1/pro/media` → the pro's library plus the taggable service options
/// (the active Service taxonomy the PATCH validates `serviceIds` against),
/// returned together so the editor is a single round-trip.
public struct ProManagedMediaListResponse: Decodable, Sendable {
    public let items: [ProManagedMediaItem]
    public let serviceOptions: [ProMediaServiceTag]
}

/// `PATCH /api/v1/pro/media/{id}` request body. All four fields are always sent
/// (the web editor sends the full set). A nil `caption` is omitted, which the
/// server coerces to null (= clear the caption), so no explicit-null encoding is
/// needed. `serviceIds` is the full replacement set (must be non-empty — the
/// editor gates Save on it). `beforeAssetId` is intentionally NOT modeled here:
/// omitting it leaves the server's before/after pairing untouched, so a core edit
/// never clobbers auto-pairing (the pairing picker is a separate increment).
struct ProMediaUpdateRequest: Encodable, Sendable {
    let caption: String?
    let isEligibleForLooks: Bool
    let isFeaturedInPortfolio: Bool
    let serviceIds: [String]
}
