import Foundation

// Wire models for the client's aftercare read — GET
// /api/v1/client/bookings/{id}/aftercare. Returns the client-visible aftercare:
// care notes (only once the pro has SENT the summary), the pro's featured
// before/after pair (else earliest per phase), and the pro's product
// recommendations with the client's current booking-checkout selection. Mirrors
// web `lib/dto/clientAftercare.ts` (`ClientAftercareDetailDTO`), which the web
// booking-detail aftercare tab renders server-side. Decode-only; the top-level
// `{ ok, … }` envelope's `ok` flag is simply ignored (unknown key).

/// GET .../aftercare → `{ ok, canShowAftercare, aftercare, beforeAfter,
/// recommendedProducts, checkoutProducts, checkoutProductsEditable }`.
public struct ClientAftercareDetail: Decodable, Sendable {
    /// Whether the client's aftercare surface should show — mirrors web's
    /// `canShowAftercareTab` gate (booking COMPLETED, or a sent summary exists).
    /// The native client hides the whole section when false.
    public let canShowAftercare: Bool
    /// The SENT aftercare summary (care notes), or nil when none is sent yet.
    public let aftercare: ClientAftercareSummary?
    /// Primary before/after pair (featured, else earliest per phase).
    public let beforeAfter: ClientAftercareBeforeAfter
    /// The pro's product recommendations from the sent summary (empty if none).
    public let recommendedProducts: [RecommendedProduct]
    /// The client's current booking-checkout product selection (empty if none).
    public let checkoutProducts: [SelectedCheckoutProduct]
    /// Whether the client may still edit their checkout-product selection —
    /// mirrors the write path's `assertClientCanEditBookingCheckoutProducts` gate
    /// (finalized aftercare, not yet in/through payment, not completed/cancelled).
    /// When false the picker renders read-only (locked).
    public let checkoutProductsEditable: Bool

    private enum CodingKeys: String, CodingKey {
        case canShowAftercare, aftercare, beforeAfter
        case recommendedProducts, checkoutProducts, checkoutProductsEditable
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canShowAftercare = try c.decode(Bool.self, forKey: .canShowAftercare)
        aftercare = try c.decodeIfPresent(ClientAftercareSummary.self, forKey: .aftercare)
        beforeAfter = try c.decode(ClientAftercareBeforeAfter.self, forKey: .beforeAfter)
        // The product-checkout fields are additive (§5 A3-prod). Default them so a
        // decode never fails against a backend that predates the contract — the
        // aftercare section still renders its notes + before/after either way.
        recommendedProducts = try c.decodeIfPresent([RecommendedProduct].self, forKey: .recommendedProducts) ?? []
        checkoutProducts = try c.decodeIfPresent([SelectedCheckoutProduct].self, forKey: .checkoutProducts) ?? []
        checkoutProductsEditable = try c.decodeIfPresent(Bool.self, forKey: .checkoutProductsEditable) ?? false
    }

    /// True when there's something to render — care notes, at least one photo,
    /// or at least one product recommendation. (`canShowAftercare` can be true
    /// for a COMPLETED booking with none of these yet.)
    public var hasContent: Bool {
        let hasNotes = (aftercare?.notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        return hasNotes || beforeAfter.hasAny || !recommendedProducts.isEmpty
    }

    /// In-app recommendations that can be added to the booking checkout.
    public var internalRecommendations: [RecommendedProduct] {
        recommendedProducts.filter { $0.isInternal }
    }

    /// External (link-out only) recommendations — no checkout stepper.
    public var externalRecommendations: [RecommendedProduct] {
        recommendedProducts.filter { !$0.isInternal }
    }
}

/// The care-notes slice of a sent aftercare summary the client may read.
public struct ClientAftercareSummary: Decodable, Sendable, Identifiable {
    public let id: String
    /// Free-text care instructions the pro wrote for the client.
    public let notes: String?
    /// ISO instant the pro sent this aftercare to the client.
    public let sentToClientAt: String?
}

/// One product the pro recommended in the aftercare summary. Internal
/// recommendations (`productId` + `product` set) can be added to the booking
/// checkout as qty steppers; external ones (`externalName`/`externalUrl`) are
/// link-out rows. Mirrors `ClientAftercareRecommendedProductDTO`.
public struct RecommendedProduct: Decodable, Sendable, Identifiable {
    public let id: String
    /// The internal Product id when this is an in-app recommendation, else nil.
    public let productId: String?
    /// Optional free-text note the pro attached.
    public let note: String?
    /// Display name for an external (link-out) recommendation, else nil.
    public let externalName: String?
    /// Link target for an external recommendation, else nil.
    public let externalUrl: String?
    /// The internal product (name/brand/price), or nil for external recs.
    public let product: CatalogProduct?

    /// The in-app product for an internal recommendation.
    public struct CatalogProduct: Decodable, Sendable {
        public let id: String
        public let name: String
        public let brand: String?
        /// Decimal-string retail price (per the wire money convention), or nil.
        public let retailPrice: String?
    }

    /// True when this is an in-app recommendation addable to booking checkout —
    /// mirrors web `isInternalRecommendation` (both `productId` and `product`
    /// present and non-empty).
    public var isInternal: Bool {
        guard
            let productId, !productId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let product, !product.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return true
    }
}

/// One line of the client's current booking-checkout product selection, with the
/// snapshotted unit price. Mirrors `ClientAftercareCheckoutProductDTO`.
public struct SelectedCheckoutProduct: Decodable, Sendable, Identifiable {
    public let recommendationId: String
    public let productId: String
    public let quantity: Int
    /// Decimal-string unit-price snapshot (per the wire money convention), or nil.
    public let unitPrice: String?

    public var id: String { recommendationId }
}

/// Primary before/after render URLs (thumb + full-size), any of which may be nil.
public struct ClientAftercareBeforeAfter: Decodable, Sendable {
    public let beforeUrl: String?
    public let afterUrl: String?
    public let beforeFullUrl: String?
    public let afterFullUrl: String?

    /// True when at least one phase has a usable URL.
    public var hasAny: Bool {
        [beforeUrl, afterUrl, beforeFullUrl, afterFullUrl]
            .contains { ($0?.isEmpty == false) }
    }

    /// Full-size-preferred "before" URL for the hero compare + tap-to-open.
    public var beforePreferred: String? { beforeFullUrl ?? beforeUrl }
    /// Full-size-preferred "after" URL for the hero compare + tap-to-open.
    public var afterPreferred: String? { afterFullUrl ?? afterUrl }
}
