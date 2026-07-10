import Foundation

// Wire models for the PRO "last minute" workspace — GET
// /api/v1/pro/last-minute/workspace (tovis-app PR #439). Mirrors
// `LastMinuteWorkspaceInitial` from lib/pro/loadLastMinuteWorkspace.ts: the
// last-minute settings (master toggle, priority offer, tier minutes, per-day
// disables) with service rules + blocks, plus the active offerings. Money fields
// are decimal strings; instants are ISO-8601 UTC.

/// `GET /api/v1/pro/last-minute/workspace` → `{ ok, timeZone, settings,
/// offerings }` (envelope's `ok` ignored).
public struct ProLastMinuteWorkspace: Decodable, Sendable {
    public let timeZone: String?
    public let settings: Settings
    public let offerings: [Offering]

    public struct Settings: Decodable, Sendable {
        public let id: String
        public let enabled: Bool
        public let priorityOfferEnabled: Bool
        public let priorityOfferMinutes: Int
        public let defaultVisibilityMode: String
        public let minCollectedSubtotal: String?
        public let tier2NightBeforeMinutes: Int
        public let tier3DayOfMinutes: Int
        public let disableMon: Bool
        public let disableTue: Bool
        public let disableWed: Bool
        public let disableThu: Bool
        public let disableFri: Bool
        public let disableSat: Bool
        public let disableSun: Bool
        public let serviceRules: [ServiceRule]
        public let blocks: [Block]
    }

    public struct ServiceRule: Decodable, Sendable, Identifiable {
        public let serviceId: String
        public let enabled: Bool
        public let minCollectedSubtotal: String?
        public var id: String { serviceId }
    }

    public struct Block: Decodable, Sendable, Identifiable {
        public let id: String
        public let startAt: String
        public let endAt: String
        public let reason: String?
    }

    public struct Offering: Decodable, Sendable, Identifiable {
        public let id: String
        public let serviceId: String
        public let name: String
        public let basePrice: String
    }
}

// MARK: - Editor request bodies (settings / rules / blocks writes)
//
// The web `/pro/last-minute` editor writes through four routes that already
// exist server-side — this is an iOS-only port (no backend change):
//   • PATCH  /api/v1/pro/last-minute/settings   the "Last-minute defaults" form
//   • PATCH  /api/v1/pro/last-minute/rules      one per-service eligibility rule
//   • POST   /api/v1/pro/last-minute/blocks     add a blocked time range
//   • DELETE /api/v1/pro/last-minute/blocks?id= remove a block
// Money fields are decimal strings (the route's `parseMoney` accepts "80" or
// "79.99"); a JSON `null` clears the floor, so those keys are always emitted.

/// PATCH body for `/api/v1/pro/last-minute/settings`. The route applies each
/// present key, so we send the whole form. `minCollectedSubtotal` is always
/// emitted: `null` clears the global floor, a decimal string sets it.
public struct ProLastMinuteSettingsPatchRequest: Encodable, Sendable {
    public let enabled: Bool
    public let defaultVisibilityMode: String
    public let minCollectedSubtotal: String?
    public let tier2NightBeforeMinutes: Int
    public let tier3DayOfMinutes: Int
    public let priorityOfferEnabled: Bool
    public let priorityOfferMinutes: Int
    public let disableMon: Bool
    public let disableTue: Bool
    public let disableWed: Bool
    public let disableThu: Bool
    public let disableFri: Bool
    public let disableSat: Bool
    public let disableSun: Bool

    public init(
        enabled: Bool,
        defaultVisibilityMode: String,
        minCollectedSubtotal: String?,
        tier2NightBeforeMinutes: Int,
        tier3DayOfMinutes: Int,
        priorityOfferEnabled: Bool,
        priorityOfferMinutes: Int,
        disableMon: Bool,
        disableTue: Bool,
        disableWed: Bool,
        disableThu: Bool,
        disableFri: Bool,
        disableSat: Bool,
        disableSun: Bool
    ) {
        self.enabled = enabled
        self.defaultVisibilityMode = defaultVisibilityMode
        self.minCollectedSubtotal = minCollectedSubtotal
        self.tier2NightBeforeMinutes = tier2NightBeforeMinutes
        self.tier3DayOfMinutes = tier3DayOfMinutes
        self.priorityOfferEnabled = priorityOfferEnabled
        self.priorityOfferMinutes = priorityOfferMinutes
        self.disableMon = disableMon
        self.disableTue = disableTue
        self.disableWed = disableWed
        self.disableThu = disableThu
        self.disableFri = disableFri
        self.disableSat = disableSat
        self.disableSun = disableSun
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, defaultVisibilityMode, minCollectedSubtotal
        case tier2NightBeforeMinutes, tier3DayOfMinutes
        case priorityOfferEnabled, priorityOfferMinutes
        case disableMon, disableTue, disableWed, disableThu, disableFri, disableSat, disableSun
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(defaultVisibilityMode, forKey: .defaultVisibilityMode)
        // Always emit the floor so an empty field clears it server-side (the
        // synthesized `encodeIfPresent` would drop the key → no clear).
        try c.encodeMoneyFloor(minCollectedSubtotal, forKey: .minCollectedSubtotal)
        try c.encode(tier2NightBeforeMinutes, forKey: .tier2NightBeforeMinutes)
        try c.encode(tier3DayOfMinutes, forKey: .tier3DayOfMinutes)
        try c.encode(priorityOfferEnabled, forKey: .priorityOfferEnabled)
        try c.encode(priorityOfferMinutes, forKey: .priorityOfferMinutes)
        try c.encode(disableMon, forKey: .disableMon)
        try c.encode(disableTue, forKey: .disableTue)
        try c.encode(disableWed, forKey: .disableWed)
        try c.encode(disableThu, forKey: .disableThu)
        try c.encode(disableFri, forKey: .disableFri)
        try c.encode(disableSat, forKey: .disableSat)
        try c.encode(disableSun, forKey: .disableSun)
    }
}

/// PATCH body for `/api/v1/pro/last-minute/rules` — upsert one per-service rule.
/// `minCollectedSubtotal` is always emitted (`null` = inherit the global floor).
public struct ProLastMinuteServiceRulePatchRequest: Encodable, Sendable {
    public let serviceId: String
    public let enabled: Bool
    public let minCollectedSubtotal: String?

    public init(serviceId: String, enabled: Bool, minCollectedSubtotal: String?) {
        self.serviceId = serviceId
        self.enabled = enabled
        self.minCollectedSubtotal = minCollectedSubtotal
    }

    private enum CodingKeys: String, CodingKey {
        case serviceId, enabled, minCollectedSubtotal
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(serviceId, forKey: .serviceId)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeMoneyFloor(minCollectedSubtotal, forKey: .minCollectedSubtotal)
    }
}

/// POST body for `/api/v1/pro/last-minute/blocks`. Instants are ISO-8601 UTC;
/// `reason` is omitted when nil (the route treats a missing reason as null).
public struct ProLastMinuteBlockCreateRequest: Encodable, Sendable {
    public let startAt: String
    public let endAt: String
    public let reason: String?

    public init(startAt: String, endAt: String, reason: String?) {
        self.startAt = startAt
        self.endAt = endAt
        self.reason = reason
    }
}

private extension KeyedEncodingContainer {
    /// Encode a nullable money-floor string, always emitting the key: a nil value
    /// writes an explicit JSON `null` (which clears the floor server-side) rather
    /// than dropping the key the way `encodeIfPresent` would.
    mutating func encodeMoneyFloor(_ value: String?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
