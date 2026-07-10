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
    /// The pro's rebook recommendation (recommended window / proposed next
    /// appointment) + the coupled next booking, or nil when no summary is sent.
    public let rebook: ClientAftercareRebook?
    /// The client's existing review of this booking (text only — media is A3-rev
    /// 4b), or nil when they haven't left one / no summary is sent. Prefills the
    /// native review block for editing.
    public let existingReview: ClientAftercareExistingReview?
    /// Whether the client may leave or edit a review right now — mirrors the web
    /// `canBookingAcceptClientReview` closeout gate (completed + finished booking,
    /// finalized aftercare, collected payment). False until a summary is sent;
    /// when false the native review block stays hidden.
    public let reviewEligible: Bool
    /// Whether the client may still edit their checkout-product selection —
    /// mirrors the write path's `assertClientCanEditBookingCheckoutProducts` gate
    /// (finalized aftercare, not yet in/through payment, not completed/cancelled).
    /// When false the picker renders read-only (locked).
    public let checkoutProductsEditable: Bool

    private enum CodingKeys: String, CodingKey {
        case canShowAftercare, aftercare, beforeAfter
        case recommendedProducts, checkoutProducts, rebook
        case existingReview, reviewEligible, checkoutProductsEditable
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
        // The rebook slice is additive (§5 A3-rebook) — nil against a backend that
        // predates it, so the section still renders notes + photos + products.
        rebook = try c.decodeIfPresent(ClientAftercareRebook.self, forKey: .rebook)
        // The review fields are additive (§5 A3-rev) — default them so a payload
        // that predates the contract still decodes (review block simply hides).
        existingReview = try c.decodeIfPresent(ClientAftercareExistingReview.self, forKey: .existingReview)
        reviewEligible = try c.decodeIfPresent(Bool.self, forKey: .reviewEligible) ?? false
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

/// The client's own review of this booking (text slice only — media is A3-rev
/// 4b). Mirrors `ClientAftercareExistingReviewDTO`; prefills the native review
/// editor. `rating` is defensively optional so a malformed payload can't wedge
/// the whole aftercare decode.
public struct ClientAftercareExistingReview: Decodable, Sendable, Identifiable {
    public let id: String
    /// The 1–5 star rating the client gave, clamped on decode. Defaults to nil
    /// when the payload omits/garbles it (the editor then starts unrated).
    public let rating: Int?
    /// Optional review headline, or nil.
    public let headline: String?
    /// Optional free-text review body, or nil.
    public let body: String?

    private enum CodingKeys: String, CodingKey {
        case id, rating, headline, body
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        // Defensive: clamp to 1…5, and treat an out-of-range/absent rating as nil
        // rather than failing the parent aftercare decode.
        if let raw = try c.decodeIfPresent(Int.self, forKey: .rating), (1...5).contains(raw) {
            rating = raw
        } else {
            rating = nil
        }
        headline = try c.decodeIfPresent(String.self, forKey: .headline)
        body = try c.decodeIfPresent(String.self, forKey: .body)
    }

    public init(id: String, rating: Int?, headline: String?, body: String?) {
        self.id = id
        self.rating = rating
        self.headline = headline
        self.body = body
    }
}

/// The pro's rebook recommendation from the sent aftercare summary + the coupled
/// next booking (if the client has already rebooked). Mirrors
/// `ClientAftercareRebookDTO` — powers the native rebook-window card. All fields
/// are defensively optional so a payload that predates the contract still decodes.
public struct ClientAftercareRebook: Decodable, Sendable {
    /// Rebook mode: "NONE" (no recommendation), "RECOMMENDED_WINDOW" (a date
    /// range the client picks within), or "BOOKED_NEXT_APPOINTMENT" (a specific
    /// time the pro proposed). Raw string — unknown values are treated as "NONE".
    public let mode: String?
    /// Pro-proposed next-appointment instant (ISO) for BOOKED_NEXT_APPOINTMENT, else nil.
    public let rebookedFor: String?
    /// Recommended-window start (ISO) for RECOMMENDED_WINDOW, else nil.
    public let windowStart: String?
    /// Recommended-window end (ISO) for RECOMMENDED_WINDOW, else nil.
    public let windowEnd: String?
    /// ISO instant the client declined the pro's proposed appointment, else nil.
    public let declinedAt: String?
    /// The coupled AFTERCARE-sourced next booking, when the client has rebooked.
    public let nextBooking: NextBooking?

    /// A summary of the coupled next appointment. Mirrors `ClientAftercareNextBookingDTO`.
    public struct NextBooking: Decodable, Sendable, Identifiable {
        public let id: String
        /// Lifecycle status (PENDING until the pro approves, etc.).
        public let status: String
        /// Scheduled instant (ISO), or nil when unset.
        public let scheduledFor: String?
    }

    /// The pro recommended a window for the client to pick a slot within.
    public var isRecommendedWindow: Bool {
        mode?.uppercased() == "RECOMMENDED_WINDOW"
    }

    /// The pro proposed a specific next-appointment time to confirm/decline.
    public var isBookedNextAppointment: Bool {
        mode?.uppercased() == "BOOKED_NEXT_APPOINTMENT"
    }

    /// The client declined the pro's proposed appointment.
    public var isDeclined: Bool {
        (declinedAt?.isEmpty == false)
    }

    /// The coupled next booking when it exists and isn't cancelled — the client
    /// has an active next appointment, so show a confirmed/pending state rather
    /// than re-offering a rebook.
    public var confirmedNextBooking: NextBooking? {
        guard let next = nextBooking, next.status.uppercased() != "CANCELLED" else { return nil }
        return next
    }

    /// The confirmed next booking is still PENDING — an aftercare-coupled rebook
    /// awaiting the pro's approval (they approve by confirming the last payment).
    /// Mirrors web's `pendingPaymentConfirmation` on the next-appointment card.
    public var isNextBookingPendingApproval: Bool {
        confirmedNextBooking?.status.uppercased() == "PENDING"
    }
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
