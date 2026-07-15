import Foundation

// Wire model for a client's PUBLIC board as seen by handle + slug — the native
// counterpart of the web `/u/[handle]/boards/[slug]` page. Decode-only.
// GET /api/v1/u/{handle}/boards/{slug} mirrors the web `loadPublicBoard`: a SHARED,
// non-hidden board addressed by the owner's handle, carrying only PUBLISHED +
// PUBLIC + APPROVED looks (PII-safe — addressed by handle, never legal name).
//
// The route is public-read and returns **404** when the handle/slug doesn't
// resolve, the board isn't SHARED, or an admin has hidden it — all
// indistinguishable by design (no enumeration). The service surfaces every 404 as
// `nil` (a plain "not found" empty state, not an error).
//
// Every field decodes with `decodeIfPresent ?? default` so an older/not-yet-
// deployed backend still decodes cleanly.

/// A client's public board: owner handle/avatar · board name/slug · a grid of the
/// board's published looks · signed-in-viewer flags.
public struct PublicBoard: Decodable, Sendable {
    public let handle: String
    /// Whether the owner's `/u/{handle}` profile is itself public — gates the
    /// back-link to their creator profile (mirrors the web page).
    public let ownerProfilePublic: Bool
    public let ownerAvatarUrl: String?
    public let boardName: String
    public let boardSlug: String
    public let looks: [PublicBoardLook]
    public let viewer: PublicBoardViewer

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = try c.decode(String.self, forKey: .handle)
        ownerProfilePublic = try c.decodeIfPresent(Bool.self, forKey: .ownerProfilePublic) ?? false
        ownerAvatarUrl = try c.decodeIfPresent(String.self, forKey: .ownerAvatarUrl)
        boardName = try c.decodeIfPresent(String.self, forKey: .boardName) ?? "Board"
        boardSlug = try c.decodeIfPresent(String.self, forKey: .boardSlug) ?? ""
        looks = try c.decodeIfPresent([PublicBoardLook].self, forKey: .looks) ?? []
        viewer = try c.decodeIfPresent(PublicBoardViewer.self, forKey: .viewer) ?? .guest
    }

    private enum CodingKeys: String, CodingKey {
        case handle, ownerProfilePublic, ownerAvatarUrl, boardName, boardSlug, looks, viewer
    }
}

/// One published look on the public board grid.
public struct PublicBoardLook: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let imageUrl: String?
    /// The web look-detail path (`/looks/{id}`). Carried for parity / future native
    /// routing; the viewer opens the image fullscreen for now.
    public let href: String
    /// Normalized subject focal point (camera C6), [0,1] top-left. The board grid's
    /// cover-cropped tiles center here; nil → center (`focalPoint`). Decoded
    /// optionally so a backend that predates the field still decodes.
    public let focalX: Double?
    public let focalY: Double?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Look"
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        href = try c.decodeIfPresent(String.self, forKey: .href) ?? "/looks/\(id)"
        focalX = try c.decodeIfPresent(Double.self, forKey: .focalX)
        focalY = try c.decodeIfPresent(Double.self, forKey: .focalY)
    }

    /// The validated focal point to crop on, or nil (center) when absent/invalid.
    public var focalPoint: MediaFocalPoint? { MediaFocalPoint(x: focalX, y: focalY) }

    private enum CodingKeys: String, CodingKey { case id, name, imageUrl, href, focalX, focalY }
}

/// Signed-in-viewer flags for a public board.
public struct PublicBoardViewer: Decodable, Sendable {
    /// The signed-in client is looking at their OWN board.
    public let isOwn: Bool
    /// The signed-in client follows the board owner.
    public let followingOwner: Bool

    static let guest = PublicBoardViewer(isOwn: false, followingOwner: false)

    public init(isOwn: Bool, followingOwner: Bool) {
        self.isOwn = isOwn
        self.followingOwner = followingOwner
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isOwn = try c.decodeIfPresent(Bool.self, forKey: .isOwn) ?? false
        followingOwner = try c.decodeIfPresent(Bool.self, forKey: .followingOwner) ?? false
    }

    private enum CodingKeys: String, CodingKey { case isOwn, followingOwner }
}

/// Envelope for GET /api/v1/u/{handle}/boards/{slug} — `{ ok, board }`, where
/// `board` is absent on a 404 (surfaced as nil by the service).
struct PublicBoardResponse: Decodable {
    let board: PublicBoard?
}
