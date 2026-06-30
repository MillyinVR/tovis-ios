import Foundation

// Wire models for the consultation form's service catalog + the proposal POST.
// Mirrors `GET /api/v1/pro/bookings/[id]/consultation-services` (inline shape in
// `route.ts`: { services, addOns, existingBookingItems }) and the body the web
// `ConsultationForm` posts to `POST .../consultation-proposal`
// ({ notes, proposedTotal, proposedServicesJson: { currency, items } }).
// Decode-only fixture (no ajv entry) — pro routes return inline shapes.

/// `GET .../consultation-services` → the bookable services + add-ons the pro can
/// put on a consultation proposal.
public struct ProConsultationServicesResponse: Decodable, Sendable {
    public let services: [ProConsultationServiceOption]
    public let addOns: [ProConsultationAddOnOption]
    public let existingBookingItems: [ProConsultationExistingItem]
}

public struct ProConsultationServiceOption: Decodable, Sendable, Identifiable {
    public let offeringId: String
    public let serviceId: String
    public let serviceName: String
    public let categoryName: String?
    public let defaultPrice: Double?
    public let defaultDurationMinutes: Int?

    public var id: String { offeringId }
}

public struct ProConsultationAddOnOption: Decodable, Sendable, Identifiable {
    public let parentOfferingId: String
    public let serviceId: String
    public let serviceName: String
    public let categoryName: String?
    public let defaultPrice: Double?
    public let defaultDurationMinutes: Int?
    public let isRecommended: Bool

    public var id: String { "\(parentOfferingId):\(serviceId)" }
}

public struct ProConsultationExistingItem: Decodable, Sendable, Identifiable {
    public let bookingServiceItemId: String
    public let serviceId: String
    public let offeringId: String?
    public let itemType: String
    public let parentItemId: String?

    public var id: String { bookingServiceItemId }
}

// MARK: - Proposal request

/// One line item posted in the consultation proposal. `price`/`durationMinutes`
/// are sent as the parsed values the server validates (price string, whole
/// minutes); exactly one item must be `BASE` and have an `offeringId`.
public struct ProConsultationProposalItem: Encodable, Sendable {
    public let bookingServiceItemId: String?
    public let offeringId: String?
    public let serviceId: String
    /// "BASE" | "ADD_ON".
    public let itemType: String
    public let label: String
    public let categoryName: String?
    /// Decimal-dollars string, e.g. "45.00".
    public let price: String
    public let durationMinutes: Int
    public let notes: String?
    public let sortOrder: Int
    /// "BOOKING" | "PROPOSAL".
    public let source: String

    public init(
        bookingServiceItemId: String?,
        offeringId: String?,
        serviceId: String,
        itemType: String,
        label: String,
        categoryName: String?,
        price: String,
        durationMinutes: Int,
        notes: String?,
        sortOrder: Int,
        source: String
    ) {
        self.bookingServiceItemId = bookingServiceItemId
        self.offeringId = offeringId
        self.serviceId = serviceId
        self.itemType = itemType
        self.label = label
        self.categoryName = categoryName
        self.price = price
        self.durationMinutes = durationMinutes
        self.notes = notes
        self.sortOrder = sortOrder
        self.source = source
    }
}
