import Foundation

// Wire models for the services-manager CRUD beyond toggle/price:
//  - the add-service library picker (`GET /pro/services/catalog`) — category tree
//    + the pro's already-added offerings (to mark/disable them);
//  - the per-offering add-ons manager (`GET`/`PUT /pro/offerings/[id]/add-ons`).
// Inline backend shapes (decode-only). See docs/PRO-BACKEND-CONTRACTS.md.

// MARK: - Add-service catalog

/// `GET /api/v1/pro/services/catalog` → `{ categories, offerings,
/// locationCapability, defaultOfferingModes }`.
public struct ProServiceCatalog: Decodable, Sendable {
    public let categories: [ProServiceCategory]
    public let offerings: [ProCatalogOffering]

    /// W6: which modes the pro can ACTUALLY be booked in, derived server-side
    /// from their bookable locations (`loadProLocationCapability`). Nil when the
    /// server predates the field — see `defaultOfferingModes`.
    public let locationCapability: ProLocationCapability?

    /// The Salon/Mobile pre-selection the server itself would apply to an
    /// offering created without stating them, so the add-service form seeds its
    /// toggles from the pro's real locations instead of assuming salon.
    ///
    /// `decodeIfPresent`: against a server that does not send it the form leaves
    /// BOTH flags unstated and lets the POST route derive them, which is the
    /// same answer — never a hardcoded salon-on/mobile-off pair.
    public let defaultOfferingModes: ProOfferingModes?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categories = try c.decode([ProServiceCategory].self, forKey: .categories)
        offerings = try c.decode([ProCatalogOffering].self, forKey: .offerings)
        locationCapability = try c.decodeIfPresent(
            ProLocationCapability.self, forKey: .locationCapability
        )
        defaultOfferingModes = try c.decodeIfPresent(
            ProOfferingModes.self, forKey: .defaultOfferingModes
        )
    }

    private enum CodingKeys: String, CodingKey {
        case categories, offerings, locationCapability, defaultOfferingModes
    }
}

/// Whether the pro has at least one bookable location of each kind.
public struct ProLocationCapability: Decodable, Sendable, Equatable {
    public let salon: Bool
    public let mobile: Bool

    public init(salon: Bool, mobile: Bool) {
        self.salon = salon
        self.mobile = mobile
    }
}

/// A Salon/Mobile pair as the offerings API expresses it.
public struct ProOfferingModes: Decodable, Sendable, Equatable {
    public let offersInSalon: Bool
    public let offersMobile: Bool

    public init(offersInSalon: Bool, offersMobile: Bool) {
        self.offersInSalon = offersInSalon
        self.offersMobile = offersMobile
    }
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
    /// The pro's "starts ticked" opt-in, set in web's offering manager and
    /// INDEPENDENT of `isRecommended`. Decoded here only so the save below can
    /// echo it back — see `ProAddOnInput`, where leaving it out WIPES it.
    ///
    /// `decodeIfPresent ?? false`: a server predating the field omits the key,
    /// and a required decode would fail the whole add-ons editor.
    public let isPreselected: Bool
    public let sortOrder: Int
    public let locationType: String?
    public let priceOverride: String?
    public let durationOverrideMinutes: Int?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        addOnServiceId = try c.decode(String.self, forKey: .addOnServiceId)
        title = try c.decode(String.self, forKey: .title)
        group = try c.decodeIfPresent(String.self, forKey: .group)
        isActive = try c.decode(Bool.self, forKey: .isActive)
        isRecommended = try c.decode(Bool.self, forKey: .isRecommended)
        isPreselected = try c.decodeIfPresent(Bool.self, forKey: .isPreselected) ?? false
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
        locationType = try c.decodeIfPresent(String.self, forKey: .locationType)
        priceOverride = try c.decodeIfPresent(String.self, forKey: .priceOverride)
        durationOverrideMinutes = try c.decodeIfPresent(Int.self, forKey: .durationOverrideMinutes)
    }

    private enum CodingKeys: String, CodingKey {
        case id, addOnServiceId, title, group, isActive, isRecommended, isPreselected
        case sortOrder, locationType, priceOverride, durationOverrideMinutes
    }
}

/// `PUT /api/v1/pro/offerings/[id]/add-ons` body item.
///
/// The route is a REPLACE, not a merge: it `deleteMany`s every row for the
/// offering and recreates the set from this payload. So a field left out of an
/// item is not "unchanged" — it is reset to the route's own default
/// (`isActive` true, `isRecommended` false, `isPreselected` false, and all three
/// overrides null).
/// Every field a pro can set therefore has to be carried back on every save,
/// which is what `init(preserving:)` is for. All four of `isRecommended`,
/// `isPreselected`, `priceOverride` and `durationOverrideMinutes` are read by
/// `GET /api/v1/offerings/add-ons` and shown to CLIENTS in the booking flow.
public struct ProAddOnInput: Encodable, Sendable {
    public let addOnServiceId: String
    public let isActive: Bool
    public let isRecommended: Bool
    public let isPreselected: Bool
    public let sortOrder: Int
    public let locationType: String?
    public let priceOverride: String?
    public let durationOverrideMinutes: Int?

    public init(
        addOnServiceId: String,
        isActive: Bool = true,
        isRecommended: Bool = false,
        isPreselected: Bool = false,
        sortOrder: Int,
        locationType: String? = nil,
        priceOverride: String? = nil,
        durationOverrideMinutes: Int? = nil
    ) {
        self.addOnServiceId = addOnServiceId
        self.isActive = isActive
        self.isRecommended = isRecommended
        self.isPreselected = isPreselected
        self.sortOrder = sortOrder
        self.locationType = locationType
        self.priceOverride = priceOverride
        self.durationOverrideMinutes = durationOverrideMinutes
    }

    /// Carry an already-attached row back through a save unchanged.
    ///
    /// The add-ons screen only toggles MEMBERSHIP. Every other field on a row it
    /// did not create was set somewhere else (web's offering manager) and must
    /// survive the round trip, or re-saving here silently reverts it.
    public init(preserving row: ProAddOnAttached) {
        self.init(
            addOnServiceId: row.addOnServiceId,
            isActive: row.isActive,
            isRecommended: row.isRecommended,
            isPreselected: row.isPreselected,
            sortOrder: row.sortOrder,
            locationType: row.locationType,
            priceOverride: row.priceOverride,
            durationOverrideMinutes: row.durationOverrideMinutes
        )
    }

    /// Build the whole replacement payload for `PUT /pro/offerings/{id}/add-ons`.
    ///
    /// Rows already on the server are echoed back verbatim; only newly switched-on
    /// services are built from defaults, and they sort AFTER everything that
    /// already had an order rather than renumbering the pro's arrangement.
    ///
    /// - Parameters:
    ///   - eligibleOrder: `addOnServiceId`s of the eligible library, in display order.
    ///   - attached: the ids the pro currently has switched on.
    ///   - existing: the server's current rows, keyed by `addOnServiceId`.
    public static func replacementSet(
        eligibleOrder: [String],
        attached: Set<String>,
        existing: [String: ProAddOnAttached]
    ) -> [ProAddOnInput] {
        var nextSortOrder = (existing.values.map(\.sortOrder).max() ?? -1) + 1
        var items: [ProAddOnInput] = []
        for serviceId in eligibleOrder where attached.contains(serviceId) {
            if let row = existing[serviceId] {
                items.append(ProAddOnInput(preserving: row))
            } else {
                items.append(ProAddOnInput(addOnServiceId: serviceId, sortOrder: nextSortOrder))
                nextSortOrder += 1
            }
        }
        return items
    }
}
