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

/// `POST /pro/calendar/blocked` body. `locationId` is required; a nil `note` is
/// omitted (synthesized `encodeIfPresent`).
struct CreateBlockRequest: Encodable {
    let startsAt: String
    let endsAt: String
    let note: String?
    let locationId: String
}

/// `PATCH /pro/calendar/blocked/[id]` body. The edit flow always sends the window
/// + note (empty note clears it server-side); location is not editable here.
struct UpdateBlockRequest: Encodable {
    let startsAt: String?
    let endsAt: String?
    let note: String?
}
