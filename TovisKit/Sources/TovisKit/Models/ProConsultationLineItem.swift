import Foundation

/// One line on a consultation proposal — a service the pro is quoting, either
/// carried over from the booking (`source: "BOOKING"`) or added by the pro
/// during the consultation (`source: "PROPOSAL"`).
///
/// Moved out of `ProConsultationFormView` in round-3 queue item 15: it is a pure
/// value type with an ordering rule, and `ProBookingDetail.initialConsultationItems`
/// needs it, so keeping it in the app target meant neither could be tested.
public struct ProConsultationLineItem: Identifiable {
    public let id = UUID()
    public var bookingServiceItemId: String?
    public var offeringId: String?
    public var serviceId: String
    public var itemType: String
    public var label: String
    public var categoryName: String?
    public var price: String
    public var durationMinutes: String
    public var notes: String
    public var sortOrder: Int
    public var source: String

    public init(
        bookingServiceItemId: String? = nil,
        offeringId: String? = nil,
        serviceId: String,
        itemType: String,
        label: String,
        categoryName: String? = nil,
        price: String,
        durationMinutes: String,
        notes: String,
        sortOrder: Int,
        source: String,
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

    /// Port of web's `sortLineItems` — by `sortOrder`, then the booking's own
    /// services before ones the pro added, then alphabetically by label.
    public static func sorted(_ items: [ProConsultationLineItem]) -> [ProConsultationLineItem] {
        items.sorted { a, b in
            if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
            if a.source != b.source { return a.source == "BOOKING" }
            return a.label < b.label
        }
    }
}
