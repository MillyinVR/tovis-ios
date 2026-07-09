import Foundation

// Wire models for the PRO's OWN editable profile + offerings management.
// `ProMyProfile` mirrors the shared select in `app/api/v1/pro/profile/route.ts`
// (GET added so native can learn its own professionalId — the web server-renders
// it). `ProOfferingAdmin` mirrors `offeringToDto` (GET /pro/offerings). Both are
// inline backend shapes (decode-only). See docs/PRO-BACKEND-CONTRACTS.md.

/// `GET`/`PATCH /api/v1/pro/profile` → `{ ok, profile }`.
public struct ProMyProfileResponse: Decodable, Sendable {
    public let profile: ProMyProfile
}

public struct ProMyProfile: Decodable, Sendable {
    public let id: String
    public let businessName: String?
    public let handle: String?
    public let bio: String?
    public let location: String?
    public let avatarUrl: String?
    public let professionType: String?
    public let nameDisplay: String?
    public let isPremium: Bool
    /// Public social presence (tovis-app PR #478). Handles stored without "@";
    /// websiteUrl is a full https:// URL. Optional so an older backend decodes.
    public let instagramHandle: String?
    public let tiktokHandle: String?
    public let websiteUrl: String?
}

/// `GET /api/v1/pro/profile/handle-available?handle=` → live vanity-handle check.
/// `status` is one of available/taken/reserved/invalid/yours; `suggestions` is
/// present only when the handle is taken.
public struct ProHandleAvailability: Decodable, Sendable {
    public let handle: String
    public let status: String
    public let message: String
    public let suggestions: [String]?

    /// Statuses that must block Save — the handle can't be persisted as-is
    /// (mirrors the web `BLOCKING_HANDLE_STATUSES`).
    public var isBlocking: Bool {
        status == "taken" || status == "reserved" || status == "invalid"
    }

    public var isPositive: Bool {
        status == "available" || status == "yours"
    }
}

/// `GET /api/v1/pro/offerings` → `{ offerings: [...] }` (the pro's own services,
/// active or not — distinct from the public `ProOffering` projection).
public struct ProOfferingsResponse: Decodable, Sendable {
    public let offerings: [ProOfferingAdmin]
}

/// `{ offering }` envelope for create/update/get of a single offering.
public struct ProOfferingResponse: Decodable, Sendable {
    public let offering: ProOfferingAdmin
}

public struct ProOfferingAdmin: Decodable, Sendable, Identifiable {
    public let id: String
    public let serviceId: String
    public let description: String?
    public let customImageUrl: String?
    public let offersInSalon: Bool
    public let offersMobile: Bool
    public let salonPriceStartingAt: String?
    public let salonDurationMinutes: Int?
    public let mobilePriceStartingAt: String?
    public let mobileDurationMinutes: Int?
    /// Typical rebook interval in days; drives the wrap-up rebook-window
    /// suggestion. Optional so older backends decode (`nil` = no suggestion).
    public let rebookIntervalDays: Int?
    public let isActive: Bool
    public let serviceName: String
    public let categoryName: String?
    public let serviceDefaultImageUrl: String?
    public let minPrice: String?

    /// The image to show: the pro's custom override, else the service default.
    public var displayImageUrl: String? { customImageUrl ?? serviceDefaultImageUrl }
}
