import Foundation

// Wire models for PRO calendar **blocked time** — the personal holds a pro drops
// on their calendar so clients can't book over them. Mirrors the inline shapes in
// `app/api/v1/pro/calendar/blocked/route.ts` (+ `/[id]`) and the `BlockDto` in
// `_shared.ts`. Inline backend shapes; decode-only. See docs/PRO-BACKEND-CONTRACTS.md.

/// One blocked window. `startsAt`/`endsAt` are ISO-8601 instants; `note` is the
/// optional reason; `locationId` is the bookable location it's pinned to.
public struct ProCalendarBlock: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let startsAt: String
    public let endsAt: String
    public let note: String?
    public let locationId: String?
}

/// `POST /pro/calendar/blocked` and `PATCH`/`GET …/[id]` → `{ block }`.
public struct ProCalendarBlockResponse: Decodable, Sendable {
    public let block: ProCalendarBlock
}

/// `DELETE /pro/calendar/blocked/[id]` → `{ id }`.
public struct ProCalendarBlockDeleteResponse: Decodable, Sendable {
    public let id: String
}

// ─── Locations (block create needs a target location) ──────────────────────────

/// One of the pro's locations (`GET /pro/locations` → `{ locations }`). Models the
/// fields the calendar's block flow and the locations editor need; unknown keys
/// are ignored. `city`/`state`/`postalCode`/`advanceNoticeMinutes` are optional —
/// they back the edit sheet (e.g. a mobile base's ZIP + the per-location lead time).
public struct ProLocationSummary: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let type: String?
    public let name: String?
    public let isPrimary: Bool
    public let isBookable: Bool
    public let formattedAddress: String?
    public let timeZone: String?
    public let city: String?
    public let state: String?
    public let postalCode: String?
    public let advanceNoticeMinutes: Int?

    /// True for the ZIP-anchored travel base (`MOBILE_BASE`).
    public var isMobileBase: Bool { type == "MOBILE_BASE" }
}

public struct ProLocationsResponse: Decodable, Sendable {
    public let locations: [ProLocationSummary]
}

// ─── Request bodies ─────────────────────────────────────────────────────────────

/// `POST /pro/calendar/blocked` body. A nil `note` is omitted (synthesized
/// `encodeIfPresent`), and so is a nil `locationId` — which is the point: the
/// server reads an ABSENT locationId as "blocks all locations", matching
/// `CalendarBlock.locationId String?` in the Prisma schema. Note it must be
/// omitted rather than sent as `""`; the route refuses an empty string precisely
/// so blanket-blocking every location cannot happen by accident (tovis-app #794).
struct CreateBlockRequest: Encodable {
    let startsAt: String
    let endsAt: String
    let note: String?
    let locationId: String?
}

/// What a PATCH should do with the block's location. Three states, because two
/// are not enough: the route reads an ABSENT `locationId` as "leave the scope
/// alone" and an explicit `null` as "apply this block to every location". A plain
/// `String?` cannot express both — nil would encode as absent — and conflating
/// them means an ordinary time edit silently widens a location-scoped block to
/// all locations (tovis-app #794).
public enum BlockScopeUpdate: Equatable, Sendable {
    /// Omit `locationId` entirely.
    case unchanged
    /// Send `locationId: null` — the block applies everywhere.
    case allLocations
    /// Send a concrete location id.
    case location(String)
}

/// `PATCH /pro/calendar/blocked/[id]` body. The edit flow always sends the window
/// + note (an empty note clears it server-side); the location is sent only when
/// the pro actually re-scoped the block — see `BlockScopeUpdate`.
struct UpdateBlockRequest: Encodable {
    let startsAt: String?
    let endsAt: String?
    let note: String?
    let scope: BlockScopeUpdate

    private enum CodingKeys: String, CodingKey {
        case startsAt, endsAt, note, locationId
    }

    // Hand-written because the three scope states need three different wire
    // shapes: omitted, explicit null, and a value.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(startsAt, forKey: .startsAt)
        try container.encodeIfPresent(endsAt, forKey: .endsAt)
        try container.encodeIfPresent(note, forKey: .note)

        switch scope {
        case .unchanged:
            break
        case .allLocations:
            try container.encodeNil(forKey: .locationId)
        case let .location(id):
            try container.encode(id, forKey: .locationId)
        }
    }
}
