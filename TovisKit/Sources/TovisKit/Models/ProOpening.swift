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

    /// Whether a CLIENT can still see and claim this opening's time (tovis-app
    /// F16). Optional so an older server, which sends no such key, decodes to
    /// nil rather than failing the whole list; `visibility` reads that as
    /// `.notChecked`, i.e. say nothing.
    public let clientVisibility: String?

    /// The decoded verdict. Never throws on an unknown value: a server that
    /// grows a new state must leave this card silent, not wrong.
    public var visibility: ProOpeningClientVisibility {
        ProOpeningClientVisibility.from(clientVisibility)
    }

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

// MARK: - Client visibility (tovis-app F16)

/// Why clients can — or can no longer — see one of the pro's own openings.
///
/// A last-minute opening keeps its `ACTIVE` row when the slot underneath it is
/// booked, blocked, or falls out of the pro's hours. Since tovis-app F15 the
/// client feeds hide it; this list is the only place the pro, who is the only
/// person able to fix any of it, would ever find out.
///
/// Mirrors the server enum in `lib/lastMinute/proOpeningVisibility.ts` and the
/// web copy in `app/pro/last-minute/OpeningsClient.tsx` — the two surfaces have
/// to say the same thing about the same row.
public enum ProOpeningClientVisibility: String, Sendable, CaseIterable {
    /// Live: the pro's schedule can still serve this time.
    case visible = "VISIBLE"
    /// A booking for that time is in flight. Transient, and needs no pro action.
    case beingClaimed = "BEING_CLAIMED"
    case timeBooked = "TIME_BOOKED"
    case timeBlocked = "TIME_BLOCKED"
    case outsideWorkingHours = "OUTSIDE_WORKING_HOURS"
    case workingHoursMissing = "WORKING_HOURS_MISSING"
    case tooSoon = "TOO_SOON"
    case tooFarAhead = "TOO_FAR_AHEAD"
    case offBookingGrid = "OFF_BOOKING_GRID"
    case locationUnavailable = "LOCATION_UNAVAILABLE"
    case locationTimeZoneMissing = "LOCATION_TIME_ZONE_MISSING"
    case noActiveService = "NO_ACTIVE_SERVICE"
    /// Not asked — the opening is already booked, cancelled, expired or past.
    case notChecked = "NOT_CHECKED"

    /// Anything unrecognised, including a missing key, is silence. A verdict we
    /// cannot read must never render as a fault, and never as an assurance.
    public static func from(_ raw: String?) -> ProOpeningClientVisibility {
        guard let raw else { return .notChecked }
        return ProOpeningClientVisibility(rawValue: raw.uppercased()) ?? .notChecked
    }

    /// Something the pro has to go and put right, so the card should shout.
    /// `beingClaimed` is deliberately NOT one: a hold on the slot is usually a
    /// client mid-claim on this very opening — the feature working.
    public var isFault: Bool {
        switch self {
        case .visible, .notChecked, .beingClaimed:
            return false
        case .timeBooked, .timeBlocked, .outsideWorkingHours, .workingHoursMissing,
             .tooSoon, .tooFarAhead, .offBookingGrid, .locationUnavailable,
             .locationTimeZoneMissing, .noActiveService:
            return true
        }
    }

    /// What the card says, or nil when there is nothing worth saying. Same
    /// sentences as the web badge.
    public var noticeText: String? {
        switch self {
        case .visible, .notChecked:
            return nil
        case .beingClaimed:
            return "On hold — a booking for this time is in progress."
        case .timeBooked:
            return "Not visible to clients — that time is already booked."
        case .timeBlocked:
            return "Not visible to clients — you have blocked that time."
        case .outsideWorkingHours:
            return "Not visible to clients — that time is outside your working hours."
        case .workingHoursMissing:
            return "Not visible to clients — this location has no working hours set."
        case .tooSoon:
            return "Not visible to clients — it is now inside your advance-notice window."
        case .tooFarAhead:
            return "Not visible to clients — it is further ahead than you take bookings."
        case .offBookingGrid:
            return "Not visible to clients — the start no longer lines up with your booking times."
        case .locationUnavailable:
            return "Not visible to clients — that location is no longer bookable."
        case .locationTimeZoneMissing:
            return "Not visible to clients — that location has no time zone set."
        case .noActiveService:
            return "Not visible to clients — none of its services is active any more."
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
