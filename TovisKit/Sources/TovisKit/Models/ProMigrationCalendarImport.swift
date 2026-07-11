import Foundation

// Wire models for the pro migration wizard's **calendar import** step (increment 4)
// — the native counterpart of the web `/pro/migrate/calendar` flow
// (MigrateCalendarClient.tsx): supply an .ics (file OR read-only feed URL) →
// preview how each event will land (booking / blocked time / client history /
// skipped) → review + optionally exclude rows → commit. A feed URL can also be
// kept in sync afterwards.
//
// Like the clients step, these routes already exist as JSON endpoints with no
// DTO/zod (the contract lives as plain types in
// `tovis-app/lib/migration/calendarImportServer.ts` + `calendarFeed.ts` +
// `calendarFeedSubscription.ts`), behind the same `ENABLE_PRO_MIGRATION`
// 404-when-off gate — so this is an **iOS-only** port with no paired web change:
//   • POST /pro/migrate/calendar/fetch         { url }               → { ics }
//   • POST /pro/migrate/calendar/preview        { ics }               → { rows, summary }
//   • POST /pro/migrate/calendar/commit         { ics, excludeUids }  → { created, skipped, failed }
//   • POST /pro/migrate/calendar/subscription   { url }               → { subscription }
//
// The client never parses the .ics — it shuttles the raw text (read from a file
// or fetched by the SSRF-guarded /fetch route) straight to preview/commit, which
// parse it server-side. So, unlike the clients step, there is no on-device
// parser here at all. Import is silent — createProBooking/upsertProClient in
// import mode never message a client.

// MARK: - Classification

/// How one parsed iCal event will land (`CalendarEventClassification`). Kept as
/// the raw string on the row (tolerant of unknown values) with `kind` deriving
/// the enum for the UI.
public enum CalendarEventClassification: String, Sendable {
    case booking = "BOOKING"
    case block = "BLOCK"
    case history = "HISTORY"
    case skip = "SKIP"
}

// MARK: - Preview response

/// One evaluated preview row (`CalendarPreviewRow`). `uid` is the source event's
/// stable id — the same value commit's `excludeUids` uses, so it must round-trip
/// unchanged. `start`/`end` are ISO-8601 instants (end may be null).
public struct CalendarImportPreviewRow: Decodable, Sendable, Identifiable, Equatable {
    public let uid: String
    public let summary: String
    public let start: String
    public let end: String?
    public let classification: String
    public let matchedServiceId: String?
    public let matchedServiceName: String?
    public let clientName: String?
    public let isRecurring: Bool
    public let reason: String

    public var id: String { uid }

    public var kind: CalendarEventClassification? { CalendarEventClassification(rawValue: classification) }

    /// The title line the review card shows — the client's name if we resolved
    /// one, else the event summary, else a placeholder (mirrors web
    /// `row.clientName ?? (row.summary || 'Untitled')`).
    public var title: String {
        if let clientName, !clientName.isEmpty { return clientName }
        let trimmed = summary.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

/// Preview totals (`CalendarImportPreview.summary`).
public struct CalendarImportPreviewSummary: Decodable, Sendable, Equatable {
    public let total: Int
    public let bookings: Int
    public let blocks: Int
    public let history: Int
    public let skipped: Int
}

/// `POST /pro/migrate/calendar/preview` envelope (the `ok:true` field is ignored
/// by `Decodable`).
public struct CalendarImportPreviewResponse: Decodable, Sendable {
    public let rows: [CalendarImportPreviewRow]
    public let summary: CalendarImportPreviewSummary
}

// MARK: - Fetch response

/// `POST /pro/migrate/calendar/fetch` envelope — the raw .ics text the server
/// pulled from the pro's read-only feed URL (SSRF-guarded server-side).
public struct CalendarFeedFetchResponse: Decodable, Sendable {
    public let ics: String
}

// MARK: - Commit response

/// What commit materialized (`CalendarCommitResult.created`).
public struct CalendarImportCommitCreated: Decodable, Sendable, Equatable {
    public let bookings: Int
    public let blocks: Int
    public let history: Int
}

/// `POST /pro/migrate/calendar/commit` envelope (`CalendarCommitResult`).
public struct CalendarImportCommitResponse: Decodable, Sendable, Equatable {
    public let created: CalendarImportCommitCreated
    public let skipped: Int
    public let failed: Int
}

// MARK: - Feed subscription

/// The pro's persistent calendar feed subscription (`CalendarFeedSubscriptionDto`)
/// — set when the pro opts to keep a feed URL synced after importing. `status` is
/// the raw enum string (ACTIVE / PAUSED / …), tolerant of unknown values.
public struct CalendarFeedSubscription: Decodable, Sendable, Equatable {
    public let feedUrl: String
    public let status: String
    public let lastSyncedAt: String?
    public let lastSyncError: String?
}

/// `POST /pro/migrate/calendar/subscription` envelope. `subscription` is null when
/// none is connected (the GET case); the connect POST always returns one.
public struct CalendarFeedSubscriptionResponse: Decodable, Sendable {
    public let subscription: CalendarFeedSubscription?
}

// MARK: - Request bodies

/// `{ url }` for the fetch + subscription routes.
struct CalendarFeedUrlRequestBody: Encodable {
    let url: String
}

/// `{ ics, excludeUids? }` for preview + commit. `excludeUids` is
/// `encodeIfPresent` — omitted for preview (which ignores it) and the excluded
/// set for commit, matching the web's two fetch bodies.
struct CalendarImportRequestBody: Encodable {
    let ics: String
    let excludeUids: [String]?
}
