import Foundation

// Wire models for the pro's ONE media library — the native twin of the web
// `/pro/portfolio` screen, whose top zone IS the public portfolio.
//
// Mirrors `tovis-app/app/pro/portfolio/_data/proPortfolioTypes.ts`, re-exported
// through `lib/dto/index.ts`, served by `GET /api/v1/pro/portfolio`. That route
// and the web page share one builder (`buildProPortfolioModel`), so a zone, a
// count or a consent hold cannot mean one thing here and another in a browser.
//
// This replaces the "My media" model, which showed a flat grid with two
// INDEPENDENT visibility toggles (Looks / portfolio). The server welds those
// together — publishing derives `visibility: PUBLIC` and publishes a LookPost —
// so two toggles were a lie the pro had to unlearn. Here publishing is one act
// with its destinations named, and public-vs-private is carried by which zone a
// tile sits in rather than by a badge.
//
// 🔴 Named `ProLibrary*`, NOT `ProPortfolio*` as on the server. `ProPortfolioTile`
// is already taken in this module by the PUBLIC profile's grid tile
// (`ProProfile.swift`, from `ProPublicProfileDto`) — a client-facing type with a
// different shape and a different job. Two same-named types would not just fail
// to compile, they would invite exactly the confusion the name collision hints
// at: one is what a stranger sees, this one is what the pro decides from. The
// wire keys are unchanged, so decoding is unaffected; only the Swift type names
// differ, and each carries the DTO it mirrors in its doc comment.

/// Which zone a tile sits in. Position carries public-vs-private INSTEAD of a
/// badge, so a tile's chip is only ever something the pro DECIDED.
public enum ProLibraryZone: String, Decodable, Sendable {
    case publicZone = "PUBLIC"
    case uploads = "UPLOADS"
    case sessions = "SESSIONS"
}

/// The one mark a tile may carry. `signatureCover` is a single chip, not two —
/// the pro made one decision about that photo twice over.
public enum ProLibraryMark: String, Decodable, Sendable {
    case signature = "SIGNATURE"
    case cover = "COVER"
    case signatureCover = "SIGNATURE_COVER"

    public var label: String {
        switch self {
        case .signature: return "Signature"
        case .cover: return "Cover"
        case .signatureCover: return "Signature · Cover"
        }
    }
}

/// Why the consent sheet's one action is unavailable. Mirrors
/// `ProLibraryNudgeBlock`.
public enum ProLibraryNudgeBlock: String, Decodable, Sendable {
    case noAftercare = "NO_AFTERCARE"
    case noContact = "NO_CONTACT"
    case noBooking = "NO_BOOKING"
}

/// A photo the CLIENT has not released. This is a client-safety rule, not a pro
/// permission: a session photo stays private until the client attaches it to a
/// review or ticks media use in their aftercare.
public struct ProLibraryConsentHold: Decodable, Sendable, Hashable {
    /// First name only — it is their photo.
    public let clientFirstName: String
    /// Nil when the hold came from the storage bucket alone, with no booking to
    /// nudge against.
    public let bookingId: String?
    /// 🔴 The single gate for the nudge button. The server refuses for more than
    /// one reason (no aftercare to re-send, no email or phone on the client), so
    /// a screen that re-derives "can I nudge?" from any one of them will offer a
    /// control the write boundary rejects.
    public let canNudge: Bool
    /// Set exactly when `canNudge` is false.
    public let nudgeBlock: ProLibraryNudgeBlock?
}

/// Live engagement for a PUBLIC photo. Nil for anything private — a photo that
/// has never been public has NO numbers rather than zeroed ones, and rendering
/// 0s would read as failure instead of absence.
public struct ProLibraryEngagement: Decodable, Sendable, Hashable {
    public let views: Int
    public let likes: Int
    public let saves: Int
    public let comments: Int
    public let shares: Int
    /// Bookings attributed to this look (`Booking.sourceLookPostId`).
    public let booked: Int
}

// `Identifiable` only — deliberately not `Hashable`. Its `before` is a
// `LooksPairedBefore`, which isn't Hashable, and nothing here needs it: `ForEach`
// and `.sheet(item:)` both key off `id`.
public struct ProLibraryTile: Decodable, Sendable, Identifiable {
    public let id: String
    public let src: String
    public let caption: String?
    public let isVideo: Bool
    public let mediaType: MediaType
    public let serviceIds: [String]
    /// Opt-in before/after pairing. INDICATED on the tile, never rendered as a
    /// live comparison slider: a recognised gesture wins the scroll, and the tap
    /// belongs to the tile.
    public let before: LooksPairedBefore?
    /// The STORED pairing, which is not the same fact as `before`: that one is
    /// nil whenever the paired row can't be drawn (a video "after", an
    /// unreadable asset), while this is the column the editor's picker must
    /// reflect. Optional so a server that predates it decodes to nil rather
    /// than failing the whole screen.
    public let beforeAssetId: String?
    public let mark: ProLibraryMark?
    /// Set only on PUBLIC tiles.
    public let engagement: ProLibraryEngagement?
    /// Set only on tiles the client has not released. Publishing is refused.
    public let hold: ProLibraryConsentHold?
    /// ISO-8601 — when this went public. Nil while private.
    public let publishedAt: String?

    public var isHeld: Bool { hold != nil }
    public var isPublic: Bool { publishedAt != nil }
}

/// A private zone, grouped by where the photo CAME FROM — so the consent rule is
/// stated once per group instead of repeated on every tile.
public struct ProLibraryGroup: Decodable, Sendable, Identifiable {
    public let zone: ProLibraryZone
    public let title: String
    public let blurb: String
    /// Total in this group, which may exceed `tiles.count`.
    public let count: Int
    /// Gold note, e.g. "4 waiting". Nil when nothing is held.
    public let note: String?
    public let tiles: [ProLibraryTile]
    /// How many more exist beyond the page shown. 0 → no "Show more".
    public let remaining: Int

    public var id: String { zone.rawValue }
}

public struct ProLibraryFilter: Decodable, Sendable, Identifiable {
    public let key: String
    public let label: String
    public let count: Int?
    public let active: Bool

    public var id: String { key }
}

/// The launch nudge: photos exist, none are public. Named after what it COSTS
/// the pro, and offering only photos that need no client permission — an
/// invitation that cannot dead-end in a refusal.
public struct ProLibraryLead: Decodable, Sendable {
    public let title: String
    public let body: String
    public let ctaLabel: String
    public let shots: [ProLibraryTile]
}

public struct ProLibraryCounts: Decodable, Sendable {
    public let total: Int
    public let publicCount: Int
    public let privateCount: Int
    public let heldCount: Int
}

/// One taggable service, as the tile editor's picker renders it. The same
/// taxonomy `PATCH /api/v1/pro/media/{id}` validates `serviceIds` against.
public struct ProLibraryServiceOption: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String

    /// The shape `ProServiceTagPicker` renders. The picker is shared with the
    /// new-post composer, so one control serves both rather than each library
    /// surface growing its own tag list.
    public var asServiceTag: ProMediaServiceTag {
        ProMediaServiceTag(serviceId: id, name: name)
    }
}

public struct ProLibraryRoutes: Decodable, Sendable {
    /// Where the library lives on web: the pro's own profile, portfolio tab.
    /// The VALUE moved there; the KEY must not change — this is non-optional,
    /// so a rename server-side fails the decode and blanks the native screen.
    public let portfolio: String
    public let uploadNew: String
    public let proHome: String
}

/// `GET /api/v1/pro/portfolio` → the whole screen.
public struct ProLibraryPageModel: Decodable, Sendable {
    public let brandDisplayName: String
    public let routes: ProLibraryRoutes
    public let title: String
    /// Derived, never invented — e.g. "69 photos here. None of them public yet."
    public let subtitle: String
    public let counts: ProLibraryCounts
    public let filters: [ProLibraryFilter]
    /// Search only earns its place once the library is large.
    public let showSearch: Bool
    public let activeFilter: String
    public let searchQuery: String?
    public let publicTiles: [ProLibraryTile]
    public let lead: ProLibraryLead?
    public let groups: [ProLibraryGroup]
    /// True only when the pro owns no media at all.
    public let isBlank: Bool
    public let publicProfileHref: String?
    /// Loaded with the page so opening a tile's editor costs no round-trip.
    /// Optional for the same reason as `ProLibraryTile.beforeAssetId`: a server
    /// that predates it must not blank the whole library.
    public let serviceOptions: [ProLibraryServiceOption]?
}

struct ProLibraryResponse: Decodable, Sendable {
    let portfolio: ProLibraryPageModel
}
