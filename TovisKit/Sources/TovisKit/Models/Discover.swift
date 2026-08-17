import Foundation

// Wire models for Discover — GET /api/v1/search/pros (the geo pro search the web
// SearchMapClient uses) + GET /api/v1/discover/categories. Mirrors
// lib/search/contracts.ts (SearchProItemDto / SearchProLocationPreviewDto) and
// lib/discovery/categoryTypes.ts. Only the rendered subset is modeled; unknown
// keys are ignored.
//
// These routes are UNAUTHENTICATED, so a location's address and placeId come
// back nulled and its coordinates coarsened to a ~1.1km grid unless the pro
// published that address (`isAddressPublic`, W7). distanceMiles is computed
// server-side from the exact point, so it stays accurate either way. Anything
// that would send a client TO a location must go through `publishedAddress` /
// `isNavigable` on `SearchProLocation` — never through lat/lng alone.

// MARK: - GET /api/v1/search/pros

struct SearchProsResponse: Decodable, Sendable {
    let items: [SearchProItem]
    let nextCursor: String?
}

public struct SearchProItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let businessName: String?
    /// Pre-resolved public display name (honors the pro's nameDisplay preference).
    public let displayName: String
    public let handle: String?
    public let professionType: String?
    /// The craft as WORDS, composed by the server (`formatProfessionLabel`).
    /// Never derive this from `professionType` on the client: that map lives in
    /// ONE place, and three separate client-side transforms of the raw enum are
    /// exactly how "MANICURIST" and "Massage_Therapist" reached real screens.
    public let professionLabel: String?
    public let avatarUrl: String?
    public let locationLabel: String?
    public let distanceMiles: Double?
    public let ratingAvg: Double?
    public let ratingCount: Int
    public let minPrice: Double?
    public let supportsMobile: Bool
    public let closestLocation: SearchProLocation?
    public let primaryLocation: SearchProLocation?

    /// The location to plot: the one closest to the search origin, else primary.
    public var mapLocation: SearchProLocation? { closestLocation ?? primaryLocation }
}

public struct SearchProLocation: Decodable, Sendable, Identifiable {
    public let id: String
    public let formattedAddress: String?
    public let city: String?
    public let state: String?
    public let timeZone: String?
    public let placeId: String?
    public let lat: Double?
    public let lng: Double?
    public let isPrimary: Bool
    /// `SALON` / `SUITE` / `MOBILE_BASE` — raw, like `ProCalendarBlockLocation.type`.
    public let locationType: String?

    /// W7 (`tovis-app` #821, `lib/discovery/publicAddress.ts`): whether the
    /// address, placeId and coordinates on THIS preview are the pro's real ones
    /// because they chose to publish them. False = the preview is redacted:
    /// address and placeId nulled, coordinates coarsened to a ~1.1km grid.
    ///
    /// Optional on the wire ONLY to survive a backend older than W7 — an absent
    /// flag reads as not published, which is the safe direction. The schema
    /// requires it, and the contract gate holds the fixture to that.
    private let isAddressPublicRaw: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, formattedAddress, city, state, timeZone, placeId, lat, lng, isPrimary
        case locationType
        case isAddressPublicRaw = "isAddressPublic"
    }

    public var isAddressPublic: Bool { isAddressPublicRaw ?? false }

    /// Where the pro STARTS FROM, not somewhere clients go.
    public var isMobileBase: Bool { locationType == "MOBILE_BASE" }

    /// The address a public audience may actually be shown or routed to — nil
    /// unless the pro published it.
    ///
    /// 🔴 On web this shipped broken: Discover built a Navigate button on top of
    /// the coordinates, which are coarsened for everyone on these unauthenticated
    /// routes, so Maps got a fuzzed point with no address and snapped to the
    /// nearest building. For a mobile-only pro the only location with coordinates
    /// is their MOBILE_BASE — it pointed at a fuzzed version of their home.
    /// Branch on the flag, NEVER on "is there a lat/lng": a coarsened coordinate
    /// is still a coordinate, and that is exactly how it shipped.
    public var publishedAddress: String? {
        guard isAddressPublic, !isMobileBase else { return nil }
        guard let address = formattedAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
              !address.isEmpty else { return nil }
        return address
    }

    /// Whether this location may be offered as a destination (directions, an
    /// "Open in Maps", a copyable address). The map PIN is fine either way — a
    /// neighborhood-accurate dot is what the coarsening is for.
    public var isNavigable: Bool { publishedAddress != nil }

    /// A short "City, ST" label.
    public var cityState: String? {
        switch (city, state) {
        case let (c?, s?): return "\(c), \(s)"
        case let (c?, nil): return c
        case let (nil, s?): return s
        default: return nil
        }
    }
}

// MARK: - GET /api/v1/search/services

struct SearchServicesResponse: Decodable, Sendable {
    let items: [SearchServiceItem]
    let nextCursor: String?
}

/// One row of the service catalog (`SearchServiceItemDto`). Deliberately thin —
/// the route selects only `id`, `name` and the category, so there is **no price,
/// pro, image or count** to render. That is why a picked service hands off to
/// `searchPros(serviceId:)` rather than trying to stand on its own.
public struct SearchServiceItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let categoryId: String?
    public let categoryName: String?
    public let categorySlug: String?
}

// MARK: - GET /api/v1/discover/categories

struct DiscoverCategoriesResponse: Decodable, Sendable {
    let categories: [DiscoverCategory]
}

public struct DiscoverCategory: Decodable, Sendable, Hashable {
    public let kind: String        // "ALL" | "SERVICE_CATEGORY"
    public let id: String?         // null for ALL
    public let label: String
    public let slug: String

    /// Stable identity for ForEach (slug is unique; ALL has a null id).
    public var identity: String { id ?? "all" }
    public var isAll: Bool { kind == "ALL" }
}

// MARK: - GET /api/v1/discover/trending-tags

struct TrendingTagsResponse: Decodable, Sendable {
    let tags: [TrendingTag]
}

/// A windowed most-used look tag for the Discover surface (social-first D2).
/// `slug` is the URL key for the web tag page (/looks/tags/{slug}); `display` is
/// the label; `lookCount` is feed-visible looks carrying it in the window.
/// Mirrors `TrendingTagDto` (lib/discovery/trendingTags.ts).
public struct TrendingTag: Decodable, Sendable, Identifiable, Hashable {
    public let slug: String
    public let display: String
    public let lookCount: Int
    public var id: String { slug }
}
