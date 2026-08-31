import Foundation

// Wire models for the public professional profile — GET /api/v1/professionals/{id}.
// Mirrors `ProPublicProfileDto` (app/professionals/[id]/_data/loadProPublicProfile.ts)
// + the mapper DTOs in lib/profiles/publicProfileMappers.ts. Only the rendered
// subset is modeled; nullable fields are Swift optionals and unknown keys ignored.
//
// Every struct decodes newly-added fields with `decodeIfPresent ?? default` so an
// older (not-yet-deployed) backend that omits them still decodes cleanly.

/// Envelope for `GET /api/v1/professionals/{id}` → `{ ok, professional }`.
struct ProProfileResponse: Decodable, Sendable {
    let professional: ProProfile
}

public struct ProProfile: Decodable, Sendable {
    public let professionalId: String
    public let header: ProProfileHeader
    public let stats: ProProfileStats
    public let offerings: [ProOffering]
    /// Handle-free payment method labels (e.g. "Cash", "Venmo"). Empty when unset.
    public let acceptedPayments: [String]
    /// The pro's chosen Signature post, promoted above the grid. nil when unset
    /// (the ordinary state) or on a backend that predates the field.
    public let signature: ProProfileSignature?
    public let portfolioTiles: [ProPortfolioTile]
    public let reviews: [ProReview]
    public let isFavoritedByMe: Bool
    /// Availability line for the book bar + the brand-new-pro chips.
    public let signals: ProProfileSignals

    private enum CodingKeys: String, CodingKey {
        case professionalId, header, stats, offerings, acceptedPayments
        case signature, portfolioTiles, reviews, isFavoritedByMe, signals
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        professionalId = try c.decode(String.self, forKey: .professionalId)
        header = try c.decode(ProProfileHeader.self, forKey: .header)
        stats = try c.decode(ProProfileStats.self, forKey: .stats)
        offerings = try c.decodeIfPresent([ProOffering].self, forKey: .offerings) ?? []
        acceptedPayments = try c.decodeIfPresent([String].self, forKey: .acceptedPayments) ?? []
        signature = try c.decodeIfPresent(ProProfileSignature.self, forKey: .signature)
        portfolioTiles = try c.decodeIfPresent([ProPortfolioTile].self, forKey: .portfolioTiles) ?? []
        reviews = try c.decodeIfPresent([ProReview].self, forKey: .reviews) ?? []
        isFavoritedByMe = try c.decodeIfPresent(Bool.self, forKey: .isFavoritedByMe) ?? false
        signals = try c.decodeIfPresent(ProProfileSignals.self, forKey: .signals)
            ?? ProProfileSignals(chips: [], availabilityLine: nil)
    }
}

/// The pro's SIGNATURE post — one optional, pro-chosen piece of their own work,
/// promoted out of the grid with the profile's only inline booking action.
/// Mirrors `PublicProfileSignatureDto`.
///
/// 🔴 Never render this as "Spotlight" or "Featured". `LookPost.featuredAt` is a
/// SUPER_ADMIN editorial pick and owns "Spotlight"; "Featured" already means
/// four other things. This is the pro's own claim about their own work.
public struct ProProfileSignature: Decodable, Sendable {
    public let tile: ProPortfolioTile
    /// Already composed as "Salon: From $250 · 180 min" — never a bare figure.
    /// nil when the look carries no service the pro currently offers.
    public let priceLine: String?
    /// Web path that opens the look with its booking drawer already open
    /// (`/looks/{id}?book=1`); the native twin drives `LookDetailView`.
    public let bookHref: String?

    /// The backing look id, parsed out of `bookHref`'s `/looks/{id}` shape so the
    /// native "Book this look" opens the look sheet rather than a browser.
    public var bookLookId: String? { tile.lookId }
}

/// Availability + "New to {brand}" for the profile. Mirrors `ProProfileSignalsDto`.
///
/// 🔴 `chips` is EMPTY for an established pro by design (Tori, 2026-08-15) — not
/// because the read failed. On a page someone reaches because the work already
/// interested them, urgency signals read as pressure; a brand-new pro keeps them
/// because availability is the one real advantage they have.
public struct ProProfileSignals: Decodable, Sendable {
    public let chips: [ProProfileChip]
    public let availabilityLine: String?

    public init(chips: [ProProfileChip], availabilityLine: String?) {
        self.chips = chips
        self.availabilityLine = availabilityLine
    }

    private enum CodingKeys: String, CodingKey {
        case chips, availabilityLine
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chips = try c.decodeIfPresent([ProProfileChip].self, forKey: .chips) ?? []
        availabilityLine = try c.decodeIfPresent(String.self, forKey: .availabilityLine)
    }
}

public struct ProProfileChip: Decodable, Sendable, Identifiable {
    public let kind: String
    public let label: String

    public var id: String { kind }
}

/// Whether a CLIENT may export/share this pro's media with the pro's handle
/// watermarked on it. Mirrors `PublicProfileHeaderDto.clientExport`
/// (lib/profiles/publicProfileMappers.ts) — `enabled` is the pro's own opt-out
/// toggle, `dropsPlatformMark` mirrors `ProMembership.exportsUnbranded` for the
/// SAME pro (resolved server-side so a client viewer never needs that pro's
/// pro-authed `/pro/membership/status`).
public struct ProClientExportSettings: Decodable, Sendable, Equatable {
    public let enabled: Bool
    public let dropsPlatformMark: Bool

    public init(enabled: Bool, dropsPlatformMark: Bool) {
        self.enabled = enabled
        self.dropsPlatformMark = dropsPlatformMark
    }
}

public struct ProProfileHeader: Decodable, Sendable {
    public let id: String
    public let displayName: String
    public let businessName: String?
    public let bio: String?
    public let avatarUrl: String?
    public let professionLabel: String
    public let location: String?
    public let handle: String?
    public let displayHandle: String?
    public let isPremium: Bool
    public let isLicenseVerified: Bool
    /// Public social presence (tovis-app PR #478). Handles are stored without
    /// the leading "@"; websiteUrl is a full https:// URL. Absent on an older
    /// (not-yet-deployed) backend → nil, chips simply don't render.
    public let instagramHandle: String?
    public let tiktokHandle: String?
    public let websiteUrl: String?
    /// Absent on an older (not-yet-deployed) backend → defaults generous
    /// (enabled, unbranded), matching `SocialExportPolicy.dropsPlatformMark`'s
    /// own missing-signal default.
    public let clientExport: ProClientExportSettings

    private enum CodingKeys: String, CodingKey {
        case id, displayName, businessName, bio, avatarUrl, professionLabel
        case location, handle, displayHandle, isPremium, isLicenseVerified
        case instagramHandle, tiktokHandle, websiteUrl, clientExport
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        businessName = try c.decodeIfPresent(String.self, forKey: .businessName)
        bio = try c.decodeIfPresent(String.self, forKey: .bio)
        avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
        professionLabel = try c.decode(String.self, forKey: .professionLabel)
        location = try c.decodeIfPresent(String.self, forKey: .location)
        handle = try c.decodeIfPresent(String.self, forKey: .handle)
        displayHandle = try c.decodeIfPresent(String.self, forKey: .displayHandle)
        isPremium = try c.decodeIfPresent(Bool.self, forKey: .isPremium) ?? false
        isLicenseVerified = try c.decodeIfPresent(Bool.self, forKey: .isLicenseVerified) ?? false
        instagramHandle = try c.decodeIfPresent(String.self, forKey: .instagramHandle)
        tiktokHandle = try c.decodeIfPresent(String.self, forKey: .tiktokHandle)
        websiteUrl = try c.decodeIfPresent(String.self, forKey: .websiteUrl)
        clientExport = try c.decodeIfPresent(ProClientExportSettings.self, forKey: .clientExport)
            ?? ProClientExportSettings(enabled: true, dropsPlatformMark: true)
    }
}

public struct ProProfileStats: Decodable, Sendable {
    public let priceFromLabel: String?
    public let completedBookingsLabel: String
    public let favoritesLabel: String
    public let reviewCountLabel: String
    public let averageRatingLabel: String?
    /// Raw ProFollow count. Optional so older API deploys still decode.
    public let followerCount: Int?
    /// Published-look and follower counts, compacted server-side ("1.2K") for the
    /// pro-owner stats grid. Formatting lives on the backend so web and native
    /// can't drift; `followerCount` above stays raw for the Follow button, which
    /// nudges it optimistically. Optional so an older API deploy still decodes —
    /// the tile is then omitted rather than rendering a wrong number.
    public let looksLabel: String?
    public let followersLabel: String?
}

public struct ProOffering: Decodable, Sendable, Identifiable {
    public let id: String
    public let serviceId: String
    public let name: String
    public let description: String?
    public let imageUrl: String?
    public let pricingLines: [String]
    public let priceFromLabel: String?
    /// The same figure as `priceFromLabel`, as a number — so a caller can pick
    /// the CHEAPEST offering rather than string-comparing "$180" against "$90".
    public let priceFromNumber: Double?
    public let durationMinutes: Int?
    public let offersInSalon: Bool
    public let offersMobile: Bool
    /// Whether the current viewer has saved this offering's underlying service.
    public let isFavorited: Bool

    private enum CodingKeys: String, CodingKey {
        case id, serviceId, name, description, imageUrl, pricingLines
        case priceFromLabel, priceFromNumber, durationMinutes
        case offersInSalon, offersMobile, isFavorited
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        serviceId = try c.decode(String.self, forKey: .serviceId)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        imageUrl = try c.decodeIfPresent(String.self, forKey: .imageUrl)
        pricingLines = try c.decodeIfPresent([String].self, forKey: .pricingLines) ?? []
        priceFromLabel = try c.decodeIfPresent(String.self, forKey: .priceFromLabel)
        priceFromNumber = try c.decodeIfPresent(Double.self, forKey: .priceFromNumber)
        durationMinutes = try c.decodeIfPresent(Int.self, forKey: .durationMinutes)
        offersInSalon = try c.decodeIfPresent(Bool.self, forKey: .offersInSalon) ?? false
        offersMobile = try c.decodeIfPresent(Bool.self, forKey: .offersMobile) ?? false
        isFavorited = try c.decodeIfPresent(Bool.self, forKey: .isFavorited) ?? false
    }
}

/// The chosen "before" counterpart of an opt-in before/after pair, resolved to
/// renderable URLs. Present on a portfolio tile / review after-photo the pro or
/// client paired; nil → render as a single tile. Mirrors the web `PairedBeforeDto`.
public struct PairedBeforeMedia: Decodable, Sendable {
    public let id: String
    public let thumbUrl: String?
    public let fullUrl: String?

    /// The thumbnail to render, falling back to the full-size URL.
    public var displayUrl: String? { thumbUrl ?? fullUrl }
}

public struct ProPortfolioTile: Decodable, Sendable, Identifiable {
    public let id: String
    /// The backing `LookPost` id (web §19f). A portfolio tile IS a look, so the
    /// tile opens the look detail — the same post web's grid links to. Optional
    /// because the wire may omit it for a legacy tile with no backing look; the
    /// caller then falls back to the plain fullscreen viewer, mirroring web's
    /// `/media/[id]` fallback.
    public let lookId: String?
    public let caption: String?
    public let src: String
    public let thumbUrl: String?
    public let isVideo: Bool
    /// Whether the media is in the pro's portfolio. Note this is TRUE of every
    /// tile the public grid renders — being in the portfolio is what puts it
    /// there — so it can never distinguish one tile from another. It used to
    /// gate a "★ FEAT" chip on the first tile; that badge was fiction and is
    /// gone. The pro's real, chosen highlight is `ProProfile.signature`.
    public let isFeaturedInPortfolio: Bool
    /// Services tagged on this post — drives the "SERVICE" chip.
    public let serviceIds: [String]
    /// Display names for `serviceIds`, in the same order. Absent on a server
    /// that predates the field, so this is empty rather than optional — an empty
    /// list simply renders no chips.
    public let serviceNames: [String]
    /// Opt-in before/after pairing → render the comparison slider when present.
    public let before: PairedBeforeMedia?
    /// Likes, comments and "N recreated this" for the backing look. Always
    /// present (zeroed on an older backend); a ZERO renders as NOTHING, never as
    /// a literal "0".
    public let engagement: ProPortfolioTileEngagement

    /// Normalized subject focal point (camera C6), [0,1] top-left. Every profile
    /// surface cover-crops this tile to a different frame — a 3:4 grid cell, a
    /// 4:5 Signature card — so each needs the focal to place its window on the
    /// face. Optional so a payload from a server that predates the field still
    /// decodes; nil → center, which is exactly how these tiles cropped before.
    public let focalX: Double?
    public let focalY: Double?

    /// The thumbnail to render (falls back to the full source).
    public var displayUrl: String { thumbUrl ?? src }

    /// The validated focal point to crop on, or nil (center) when absent or
    /// invalid. Mirrors `LooksFeedItem.focalPoint` and the web `resolveFocalPoint`.
    public var focalPoint: MediaFocalPoint? { MediaFocalPoint(x: focalX, y: focalY) }

    private enum CodingKeys: String, CodingKey {
        case id, lookId, caption, src, thumbUrl, isVideo, isFeaturedInPortfolio
        case serviceIds, serviceNames, before, engagement
        case focalX, focalY
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        lookId = try c.decodeIfPresent(String.self, forKey: .lookId)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        src = try c.decode(String.self, forKey: .src)
        thumbUrl = try c.decodeIfPresent(String.self, forKey: .thumbUrl)
        isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo) ?? false
        isFeaturedInPortfolio = try c.decodeIfPresent(Bool.self, forKey: .isFeaturedInPortfolio) ?? false
        serviceIds = try c.decodeIfPresent([String].self, forKey: .serviceIds) ?? []
        serviceNames = try c.decodeIfPresent([String].self, forKey: .serviceNames) ?? []
        before = try c.decodeIfPresent(PairedBeforeMedia.self, forKey: .before)
        engagement = try c.decodeIfPresent(ProPortfolioTileEngagement.self, forKey: .engagement)
            ?? ProPortfolioTileEngagement(likeCount: 0, commentCount: 0, recreatedCount: 0)
        focalX = try c.decodeIfPresent(Double.self, forKey: .focalX)
        focalY = try c.decodeIfPresent(Double.self, forKey: .focalY)
    }
}

/// A grid tile's engagement counts. Mirrors `PublicPortfolioTileEngagement`.
public struct ProPortfolioTileEngagement: Decodable, Sendable, Equatable {
    public let likeCount: Int
    public let commentCount: Int
    /// Non-cancelled bookings citing this look as their source. Zero renders
    /// nothing at all — a tile advertising "0 recreated this" is worse than a
    /// quiet one.
    public let recreatedCount: Int

    public init(likeCount: Int, commentCount: Int, recreatedCount: Int) {
        self.likeCount = likeCount
        self.commentCount = commentCount
        self.recreatedCount = recreatedCount
    }

    private enum CodingKeys: String, CodingKey {
        case likeCount, commentCount, recreatedCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        likeCount = try c.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        commentCount = try c.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
        recreatedCount = try c.decodeIfPresent(Int.self, forKey: .recreatedCount) ?? 0
    }
}

public struct ProReview: Decodable, Sendable, Identifiable {
    public let id: String
    public let rating: Int
    public let headline: String?
    public let body: String?
    public let createdAt: String
    public let clientName: String
    public let helpfulCount: Int
    public let viewerHelpful: Bool
    public let mediaAssets: [ProReviewMedia]

    private enum CodingKeys: String, CodingKey {
        case id, rating, headline, body, createdAt, clientName
        case helpfulCount, viewerHelpful, mediaAssets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        headline = try c.decodeIfPresent(String.self, forKey: .headline)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        clientName = try c.decodeIfPresent(String.self, forKey: .clientName) ?? "Client"
        helpfulCount = try c.decodeIfPresent(Int.self, forKey: .helpfulCount) ?? 0
        viewerHelpful = try c.decodeIfPresent(Bool.self, forKey: .viewerHelpful) ?? false
        mediaAssets = try c.decodeIfPresent([ProReviewMedia].self, forKey: .mediaAssets) ?? []
    }
}

/// A photo/video attached to a review — mirrors `PublicReviewMediaDto`.
public struct ProReviewMedia: Decodable, Sendable, Identifiable {
    public let id: String
    public let url: String
    public let thumbUrl: String?
    public let isVideo: Bool
    /// Opt-in before/after pairing → this after photo renders as the slider.
    public let before: PairedBeforeMedia?

    /// Best URL for a thumbnail (thumb when available, else the full asset).
    public var displayUrl: String { thumbUrl ?? url }

    private enum CodingKeys: String, CodingKey {
        case id, url, thumbUrl, mediaType, before
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(String.self, forKey: .url)
        thumbUrl = try c.decodeIfPresent(String.self, forKey: .thumbUrl)
        let mediaType = try c.decodeIfPresent(String.self, forKey: .mediaType)
        isVideo = (mediaType ?? "").uppercased() == "VIDEO"
        before = try c.decodeIfPresent(PairedBeforeMedia.self, forKey: .before)
    }
}

/// Result of toggling a pro favorite (POST/DELETE /professionals/{id}/favorite)
/// or a service favorite (POST/DELETE /services/{id}/favorite).
public struct FavoriteResult: Decodable, Sendable {
    public let favorited: Bool
    public let count: Int
}

/// Result of toggling review "helpful" (POST/DELETE /reviews/{id}/helpful).
public struct ReviewHelpfulResult: Decodable, Sendable {
    public let helpful: Bool
    public let helpfulCount: Int
}
