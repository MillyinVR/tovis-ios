import Foundation

// Wire models for the aftercare authoring screen — GET/POST
// `/api/v1/pro/bookings/[id]/aftercare`. GET returns the booking + its existing
// aftercare summary (prefill); POST saves a draft or finalizes + sends to the
// client. Inline backend shape (decode-only). See route.ts `mapAftercareSummaryForGet`.

/// `GET .../aftercare` → `{ ok, booking }`.
public struct ProAftercareDetailResponse: Decodable, Sendable {
    public let booking: ProAftercareBooking
}

public struct ProAftercareBooking: Decodable, Sendable {
    public let id: String
    public let status: String
    public let sessionStep: String?
    public let scheduledFor: String
    public let finishedAt: String?
    public let locationTimeZone: String?
    public let aftercareSummary: ProAftercareSummaryDetail?
}

public struct ProAftercareSummaryDetail: Decodable, Sendable {
    public let id: String
    public let notes: String?
    public let rebookMode: String
    public let rebookedFor: String?
    public let rebookWindowStart: String?
    public let rebookWindowEnd: String?
    public let rebookDeclinedAt: String?
    public let rebookSlot: ProAftercareRebookSlot?
    public let draftSavedAt: String?
    public let sentToClientAt: String?
    public let lastEditedAt: String?
    public let version: Int
    public let isFinalized: Bool
    public let recommendedProducts: [ProAftercareRecommendedProduct]
}

public struct ProAftercareRebookSlot: Decodable, Sendable {
    public let id: String?
    public let offeringId: String?
    public let locationId: String?
    public let locationType: String?
    public let startsAt: String
    public let endsAt: String
}

public struct ProAftercareRecommendedProduct: Decodable, Sendable, Identifiable {
    public let id: String
    public let note: String?
    public let productId: String?
    public let externalName: String?
    public let externalUrl: String?
    public let product: CatalogProduct?

    public struct CatalogProduct: Decodable, Sendable {
        public let id: String
        public let name: String
        public let brand: String?
        public let retailPrice: String?
    }

    /// Best display name — the external name, else the catalog product name.
    public var displayName: String { externalName ?? product?.name ?? "Product" }
}

// MARK: - Save request

/// POST `.../aftercare` body. `sendToClient: false` saves a draft; `true`
/// finalizes + delivers. Mirrors the web `AftercareForm.buildPayload`.
public struct ProAftercareSaveRequest: Encodable, Sendable {
    public let notes: String
    public let recommendedProducts: [Product]
    /// "NONE" | "RECOMMENDED_WINDOW" | "BOOKED_NEXT_APPOINTMENT".
    public let rebookMode: String
    public let rebookedFor: String?
    public let rebookWindowStart: String?
    public let rebookWindowEnd: String?
    public let createRebookReminder: Bool
    public let rebookReminderDaysBefore: Int
    public let createProductReminder: Bool
    public let productReminderDaysAfter: Int
    public let sendToClient: Bool
    public let timeZone: String?
    public let version: Int?

    public struct Product: Encodable, Sendable {
        public let productId: String?
        public let externalName: String
        public let externalUrl: String
        public let note: String?

        public init(productId: String?, externalName: String, externalUrl: String, note: String?) {
            self.productId = productId
            self.externalName = externalName
            self.externalUrl = externalUrl
            self.note = note
        }
    }

    public init(
        notes: String,
        recommendedProducts: [Product],
        rebookMode: String,
        rebookedFor: String?,
        rebookWindowStart: String?,
        rebookWindowEnd: String?,
        createRebookReminder: Bool,
        rebookReminderDaysBefore: Int,
        createProductReminder: Bool,
        productReminderDaysAfter: Int,
        sendToClient: Bool,
        timeZone: String?,
        version: Int?
    ) {
        self.notes = notes
        self.recommendedProducts = recommendedProducts
        self.rebookMode = rebookMode
        self.rebookedFor = rebookedFor
        self.rebookWindowStart = rebookWindowStart
        self.rebookWindowEnd = rebookWindowEnd
        self.createRebookReminder = createRebookReminder
        self.rebookReminderDaysBefore = rebookReminderDaysBefore
        self.createProductReminder = createProductReminder
        self.productReminderDaysAfter = productReminderDaysAfter
        self.sendToClient = sendToClient
        self.timeZone = timeZone
        self.version = version
    }
}
