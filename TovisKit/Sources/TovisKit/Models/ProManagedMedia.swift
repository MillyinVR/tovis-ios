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
    /// §18d — whether this asset is the pro's current creator-page cover banner
    /// (`ProfessionalProfile.coverMediaAssetId`). Drives the editor's "Set as
    /// cover" ↔ "Remove cover" action. The server already emits it on every item
    /// (a required field, live since #599), so it decodes like the two flags above.
    public let isCoverMedia: Bool
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

/// A candidate "before" photo the pro can pair with a featured "after" — the
/// other IMAGE assets from the after's booking, render-safe. From
/// `GET /api/v1/pro/media/{id}/before-options`; mirrors the web `OwnerMediaMenu`
/// pairing picker's `BeforeOption`. The list is empty for a video, an after with
/// no booking, or a booking with no other photos.
public struct ProMediaBeforeOption: Decodable, Sendable, Identifiable {
    public let id: String
    public let thumbUrl: String
    public let phase: MediaPhase
}

/// `GET /api/v1/pro/media/{id}/before-options` → the candidate befores.
public struct ProMediaBeforeOptionsResponse: Decodable, Sendable {
    public let options: [ProMediaBeforeOption]
}

/// Three-state before/after pairing intent for a media edit — mirrors the web
/// `OwnerMediaMenu`'s `pairingTouched` gate. `.untouched` (the default) omits
/// `beforeAssetId` from the PATCH entirely, so the server leaves its before/after
/// auto-pairing alone — the correct behavior for any edit that isn't about the
/// pairing. `.set(id)` pairs with that before; `.set(nil)` sends an explicit null
/// to unpair. Only escalate to `.set(...)` once the pro actually touches the
/// picker, never on an unrelated save.
public enum ProMediaPairingEdit: Sendable, Equatable {
    case untouched
    case set(String?)
}

/// `PATCH /api/v1/pro/media/{id}` request body (matches the web `OwnerMediaMenu`
/// editor). The caption / flags / `serviceIds` are always sent: a nil `caption`
/// is omitted, which the server coerces to null (= clear); `serviceIds` is the
/// full replacement set (must be non-empty — the editor gates Save on it).
/// `beforeAssetId` is driven by `pairing` and follows the server's 3-state
/// contract (`parseBeforeAssetField`): omitted → leave pairing untouched (never
/// clobber auto-pairing); explicit null → unpair; a value → pair. Custom
/// `encode(to:)` because `Encodable` can't express "omit vs explicit-null" from
/// a single optional.
struct ProMediaUpdateRequest: Encodable, Sendable {
    let caption: String?
    let isEligibleForLooks: Bool
    let isFeaturedInPortfolio: Bool
    let serviceIds: [String]
    var pairing: ProMediaPairingEdit = .untouched

    private enum CodingKeys: String, CodingKey {
        case caption, isEligibleForLooks, isFeaturedInPortfolio, serviceIds, beforeAssetId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // A nil caption is omitted → the server coerces an absent caption to null.
        try c.encodeIfPresent(caption, forKey: .caption)
        try c.encode(isEligibleForLooks, forKey: .isEligibleForLooks)
        try c.encode(isFeaturedInPortfolio, forKey: .isFeaturedInPortfolio)
        try c.encode(serviceIds, forKey: .serviceIds)
        switch pairing {
        case .untouched:
            break // omit beforeAssetId entirely → server leaves auto-pairing alone
        case let .set(id):
            if let id { try c.encode(id, forKey: .beforeAssetId) }
            else { try c.encodeNil(forKey: .beforeAssetId) } // explicit null = unpair
        }
    }
}
