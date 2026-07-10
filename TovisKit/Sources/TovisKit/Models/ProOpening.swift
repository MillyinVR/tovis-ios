import Foundation

// Wire models for the PRO "last minute" OPENINGS surface — the create/list/cancel
// half of the web `/pro/last-minute` workspace (`OpeningsClient.tsx`), backed by
// routes that already exist:
//   • GET    /api/v1/pro/openings?hours=&take=   list the upcoming openings
//   • POST   /api/v1/pro/openings                create one (tier plans + slot)
//   • DELETE /api/v1/pro/openings?id=            cancel one
// This is an iOS-only port — no backend change. Money fields are decimal strings;
// instants are ISO-8601 UTC. The tier rollout schedule stays server-owned.

/// One row from `GET /api/v1/pro/openings` (mirrors the route's `mapOpeningDto`).
/// A **display subset** of the server DTO — extra keys the native card doesn't
/// render (launchAt, publicVisible*, the offering sub-object, …) are simply
/// ignored by `Decodable`, so this stays forward-compatible.
public struct ProOpeningDto: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String
    public let visibilityMode: String
    public let startAt: String
    public let endAt: String?
    public let note: String?
    public let locationType: String
    public let timeZone: String
    public let recipientCount: Int
    public let location: Location?
    public let services: [ServiceRow]
    public let tierPlans: [TierPlan]

    public struct Location: Decodable, Sendable {
        public let name: String?
        public let formattedAddress: String?
    }

    public struct ServiceRow: Decodable, Sendable, Identifiable {
        public let id: String
        public let serviceId: String
        public let service: Service

        public struct Service: Decodable, Sendable {
            public let name: String
            public let minPrice: String?
        }
    }

    public struct TierPlan: Decodable, Sendable, Identifiable {
        public let id: String
        public let tier: String
        public let scheduledFor: String
        public let processedAt: String?
        public let cancelledAt: String?
        public let lastError: String?
        public let offerType: String
        public let percentOff: Int?
        public let amountOff: String?
        public let freeAddOnService: FreeAddOnService?

        public struct FreeAddOnService: Decodable, Sendable {
            public let id: String
            public let name: String
        }
    }
}

// MARK: - Create request bodies

/// POST body for `/api/v1/pro/openings`. `endAt`/`note` are omitted when nil
/// (the route treats a missing value as null → server-derived end / no note);
/// `visibilityMode` is always sent (the create form always has a choice).
public struct ProOpeningCreateRequest: Encodable, Sendable {
    public let offeringIds: [String]
    public let startAt: String
    public let endAt: String?
    public let locationType: String
    public let visibilityMode: String
    public let note: String?
    public let tierPlans: [ProOpeningTierPlanRequest]

    public init(
        offeringIds: [String],
        startAt: String,
        endAt: String?,
        locationType: String,
        visibilityMode: String,
        note: String?,
        tierPlans: [ProOpeningTierPlanRequest]
    ) {
        self.offeringIds = offeringIds
        self.startAt = startAt
        self.endAt = endAt
        self.locationType = locationType
        self.visibilityMode = visibilityMode
        self.note = note
        self.tierPlans = tierPlans
    }
}

/// One tier plan in a create request. Mirrors the web `buildTierPlanRequest`
/// discriminated union: only the field relevant to `offerType` is set, the rest
/// stay nil and drop out of the JSON (synthesized `encodeIfPresent`), which the
/// route's `parseTierPlans` reads as "absent" for that tier.
public struct ProOpeningTierPlanRequest: Encodable, Sendable {
    public let tier: String
    public let offerType: String
    public let percentOff: Int?
    public let amountOff: String?
    public let freeAddOnServiceId: String?

    public init(
        tier: String,
        offerType: String,
        percentOff: Int? = nil,
        amountOff: String? = nil,
        freeAddOnServiceId: String? = nil
    ) {
        self.tier = tier
        self.offerType = offerType
        self.percentOff = percentOff
        self.amountOff = amountOff
        self.freeAddOnServiceId = freeAddOnServiceId
    }
}

// MARK: - Response envelopes

/// `GET /api/v1/pro/openings` → `{ ok, openings: [...] }` (envelope `ok` ignored).
struct ProOpeningsListResponse: Decodable, Sendable {
    let openings: [ProOpeningDto]
}

/// `POST /api/v1/pro/openings` → `{ ok, opening: {...} }` (envelope `ok` ignored).
struct ProOpeningCreateResponse: Decodable, Sendable {
    let opening: ProOpeningDto
}
