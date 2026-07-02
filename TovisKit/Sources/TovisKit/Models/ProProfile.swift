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
    public let portfolioTiles: [ProPortfolioTile]
    public let reviews: [ProReview]
    public let isFavoritedByMe: Bool

    private enum CodingKeys: String, CodingKey {
        case professionalId, header, stats, offerings, acceptedPayments
        case portfolioTiles, reviews, isFavoritedByMe
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        professionalId = try c.decode(String.self, forKey: .professionalId)
        header = try c.decode(ProProfileHeader.self, forKey: .header)
        stats = try c.decode(ProProfileStats.self, forKey: .stats)
        offerings = try c.decodeIfPresent([ProOffering].self, forKey: .offerings) ?? []
        acceptedPayments = try c.decodeIfPresent([String].self, forKey: .acceptedPayments) ?? []
        portfolioTiles = try c.decodeIfPresent([ProPortfolioTile].self, forKey: .portfolioTiles) ?? []
        reviews = try c.decodeIfPresent([ProReview].self, forKey: .reviews) ?? []
        isFavoritedByMe = try c.decodeIfPresent(Bool.self, forKey: .isFavoritedByMe) ?? false
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
}

public struct ProProfileStats: Decodable, Sendable {
    public let priceFromLabel: String?
    public let completedBookingsLabel: String
    public let favoritesLabel: String
    public let reviewCountLabel: String
    public let averageRatingLabel: String?
}

public struct ProOffering: Decodable, Sendable, Identifiable {
    public let id: String
    public let serviceId: String
    public let name: String
    public let description: String?
    public let imageUrl: String?
    public let pricingLines: [String]
    public let priceFromLabel: String?
    public let durationMinutes: Int?
    public let offersInSalon: Bool
    public let offersMobile: Bool
    /// Whether the current viewer has saved this offering's underlying service.
    public let isFavorited: Bool

    private enum CodingKeys: String, CodingKey {
        case id, serviceId, name, description, imageUrl, pricingLines
        case priceFromLabel, durationMinutes, offersInSalon, offersMobile, isFavorited
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
    public let caption: String?
    public let src: String
    public let thumbUrl: String?
    public let isVideo: Bool
    /// The first featured tile gets the "FEAT" chip, matching the web grid.
    public let isFeaturedInPortfolio: Bool
    /// Services tagged on this post — drives the "SERVICE" chip.
    public let serviceIds: [String]
    /// Opt-in before/after pairing → render the comparison slider when present.
    public let before: PairedBeforeMedia?

    /// The thumbnail to render (falls back to the full source).
    public var displayUrl: String { thumbUrl ?? src }

    private enum CodingKeys: String, CodingKey {
        case id, caption, src, thumbUrl, isVideo, isFeaturedInPortfolio, serviceIds, before
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        src = try c.decode(String.self, forKey: .src)
        thumbUrl = try c.decodeIfPresent(String.self, forKey: .thumbUrl)
        isVideo = try c.decodeIfPresent(Bool.self, forKey: .isVideo) ?? false
        isFeaturedInPortfolio = try c.decodeIfPresent(Bool.self, forKey: .isFeaturedInPortfolio) ?? false
        serviceIds = try c.decodeIfPresent([String].self, forKey: .serviceIds) ?? []
        before = try c.decodeIfPresent(PairedBeforeMedia.self, forKey: .before)
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
