import Foundation

// Wire models for the public professional profile — GET /api/v1/professionals/{id}.
// Mirrors `ProPublicProfileDto` (app/professionals/[id]/_data/loadProPublicProfile.ts)
// + the mapper DTOs in lib/profiles/publicProfileMappers.ts. Only the rendered
// subset is modeled; nullable fields are Swift optionals and unknown keys ignored.

/// Envelope for `GET /api/v1/professionals/{id}` → `{ ok, professional }`.
struct ProProfileResponse: Decodable, Sendable {
    let professional: ProProfile
}

public struct ProProfile: Decodable, Sendable {
    public let professionalId: String
    public let header: ProProfileHeader
    public let stats: ProProfileStats
    public let offerings: [ProOffering]
    public let portfolioTiles: [ProPortfolioTile]
    public let reviews: [ProReview]
    public let isFavoritedByMe: Bool
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
}

public struct ProPortfolioTile: Decodable, Sendable, Identifiable {
    public let id: String
    public let caption: String?
    public let src: String
    public let thumbUrl: String?
    public let isVideo: Bool

    /// The thumbnail to render (falls back to the full source).
    public var displayUrl: String { thumbUrl ?? src }
}

public struct ProReview: Decodable, Sendable, Identifiable {
    public let id: String
    public let rating: Int
    public let headline: String?
    public let body: String?
    public let createdAt: String
    public let clientName: String
    public let helpfulCount: Int
}