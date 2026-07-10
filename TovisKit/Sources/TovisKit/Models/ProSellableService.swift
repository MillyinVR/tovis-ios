import Foundation

// Wire model for the pro's sellable-services picker — GET /api/v1/pro/services?locationType=.
// This is the flat, base-swappable offering list the web calendar BookingModal's
// service editor picks from (mirrors `app/api/v1/pro/services/route.ts`), and the
// source for editing the services on an existing booking natively.
//
// NOTE the route returns the *service* id as `id` — the offering is a separate
// `offeringId`; both are needed to build a service-items edit. `selectedMode`
// carries the price + duration for the requested location mode and is present
// whenever a `locationType` is passed (it resolves to that mode). Money is a
// decimal string ("50.00"); durations are minutes.

/// `GET /api/v1/pro/services?locationType=SALON|MOBILE` → `{ locationType, services }`.
public struct ProSellableServicesResponse: Decodable, Sendable {
    public let services: [ProSellableService]
}

public struct ProSellableService: Decodable, Sendable, Identifiable {
    /// The route returns the *service* id here (not the offering id).
    public let id: String
    public let name: String
    public let offeringId: String
    /// Price + duration for the requested location mode (present when a
    /// `locationType` was requested; nil for a multi-mode row with none resolved).
    public let selectedMode: Mode?

    /// Alias so call sites reading a service item's `serviceId` stay legible.
    public var serviceId: String { id }

    public struct Mode: Decodable, Sendable {
        public let durationMinutes: Int?
        public let priceStartingAt: String?
    }
}
