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
