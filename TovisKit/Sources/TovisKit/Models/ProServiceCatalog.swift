import Foundation

// Wire models for the services-manager CRUD beyond toggle/price:
//  - the add-service library picker (`GET /pro/services/catalog`) — category tree
//    + the pro's already-added offerings (to mark/disable them);
//  - the per-offering add-ons manager (`GET`/`PUT /pro/offerings/[id]/add-ons`).
// Inline backend shapes (decode-only). See docs/PRO-BACKEND-CONTRACTS.md.

// MARK: - Add-service catalog

/// `GET /api/v1/pro/services/catalog` → `{ categories, offerings }`.
public struct ProServiceCatalog: Decodable, Sendable {
    public let categories: [ProServiceCategory]
    public let offerings: [ProCatalogOffering]
}

public struct ProServiceCategory: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let services: [ProCatalogService]
    public let children: [ProServiceSubcategory]
}

public struct ProServiceSubcategory: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let services: [ProCatalogService]
}

public struct ProCatalogService: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let minPrice: String
    public let defaultDurationMinutes: Int
    public let defaultImageUrl: String?
    public let isAddOnEligible: Bool
    public let addOnGroup: String?
}

public struct ProCatalogOffering: Decodable, Sendable, Identifiable {
    public let id: String
    public let serviceId: String
}

// MARK: - Add-ons manager

/// `GET /api/v1/pro/offerings/[id]/add-ons` → `{ eligible, attached }`.
public struct ProAddOns: Decodable, Sendable {
    public let eligible: [ProAddOnEligible]
    public let attached: [ProAddOnAttached]
}

public struct ProAddOnEligible: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let group: String?
    public let minPrice: String
    public let defaultDurationMinutes: Int
}

public struct ProAddOnAttached: Decodable, Sendable, Identifiable {
    public let id: String
    public let addOnServiceId: String
    public let title: String
    public let group: String?
    public let isActive: Bool
    public let isRecommended: Bool
    public let sortOrder: Int
    public let locationType: String?
    public let priceOverride: String?
    public let durationOverrideMinutes: Int?
}

/// `PUT /api/v1/pro/offerings/[id]/add-ons` body item. The route replaces the
/// whole set with `{ items: [...] }`.
public struct ProAddOnInput: Encodable, Sendable {
    public let addOnServiceId: String
    public let isActive: Bool
    public let isRecommended: Bool
    public let sortOrder: Int

    public init(addOnServiceId: String, isActive: Bool = true, isRecommended: Bool = false, sortOrder: Int) {
        self.addOnServiceId = addOnServiceId
        self.isActive = isActive
        self.isRecommended = isRecommended
        self.sortOrder = sortOrder
    }
}
