import Foundation

// Mirrors `ProReadiness` from lib/pro/readiness/proReadiness.ts — whether a pro
// is "live" and bookable, or the list of setup blockers standing in the way.
// Returned by GET /api/v1/pro/readiness inside the standard `{ ok, … }` envelope.

/// A single unmet setup requirement. String-backed with an `.unknown` fallback so
/// a blocker the backend adds later never fails to decode (same tactic as `Role`).
public enum ProReadinessBlocker: String, Decodable, Sendable, Equatable, Hashable {
    case noActiveOffering = "NO_ACTIVE_OFFERING"
    case noBookableLocation = "NO_BOOKABLE_LOCATION"
    case salonMissingAddress = "SALON_MISSING_ADDRESS"
    case mobileMissingBaseConfig = "MOBILE_MISSING_BASE_CONFIG"
    case locationMissingTimezone = "LOCATION_MISSING_TIMEZONE"
    case locationMissingWorkingHours = "LOCATION_MISSING_WORKING_HOURS"
    case locationMissingGeo = "LOCATION_MISSING_GEO"
    case offeringMissingSalonPriceOrDuration = "OFFERING_MISSING_SALON_PRICE_OR_DURATION"
    case offeringMissingMobilePriceOrDuration = "OFFERING_MISSING_MOBILE_PRICE_OR_DURATION"
    case stripeNotReady = "STRIPE_NOT_READY"
    case verificationNotApproved = "VERIFICATION_NOT_APPROVED"
    case verificationNotBroadlyDiscoverable = "VERIFICATION_NOT_BROADLY_DISCOVERABLE"
    case licenseExpired = "LICENSE_EXPIRED"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProReadinessBlocker(rawValue: raw) ?? .unknown
    }
}

/// A booking mode a ready pro is live in.
public enum LiveBookingMode: String, Decodable, Sendable, Equatable {
    case salon = "SALON"
    case mobile = "MOBILE"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LiveBookingMode(rawValue: raw) ?? .unknown
    }
}

/// The discriminated readiness result: either bookable (`ok: true`) with the live
/// modes + ready location ids, or blocked (`ok: false`) with the outstanding
/// blockers. Decoded off the `ok` flag exactly like the web union.
public enum ProReadiness: Decodable, Sendable, Equatable {
    case ready(liveModes: [LiveBookingMode], readyLocationIds: [String])
    case blocked(blockers: [ProReadinessBlocker])

    private enum CodingKeys: String, CodingKey {
        case ok, liveModes, readyLocationIds, blockers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try container.decode(Bool.self, forKey: .ok)
        if ok {
            let modes = try container.decodeIfPresent([LiveBookingMode].self, forKey: .liveModes) ?? []
            let ids = try container.decodeIfPresent([String].self, forKey: .readyLocationIds) ?? []
            self = .ready(liveModes: modes, readyLocationIds: ids)
        } else {
            let blockers = try container.decodeIfPresent([ProReadinessBlocker].self, forKey: .blockers) ?? []
            self = .blocked(blockers: blockers)
        }
    }

    /// Whether the pro is fully set up and bookable.
    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// The outstanding setup blockers (empty when ready).
    public var blockers: [ProReadinessBlocker] {
        if case let .blocked(blockers) = self { return blockers }
        return []
    }
}

/// Envelope for GET /api/v1/pro/readiness (`jsonOk({ readiness })`).
struct ProReadinessResponse: Decodable, Sendable {
    let readiness: ProReadiness
}
