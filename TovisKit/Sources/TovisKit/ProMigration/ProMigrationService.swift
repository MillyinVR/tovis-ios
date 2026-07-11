import Foundation

/// PRO data-migration wizard — the native side of the web `/pro/migrate` flow.
/// Increment 1 covers the two RSC-only "bookend" screens (entry progress +
/// review/go-live summary), fed by `summary()`. Increment 2 adds the **clients
/// import** step — `previewClientImport` + `commitClientImport`. Increment 4 adds
/// the **calendar import** step — `fetchCalendarFeed` + `previewCalendarImport` +
/// `commitCalendarImport` + `connectCalendarSubscription`. All POST to the
/// existing web routes. The services step is a later increment.
///
/// Dark unless `ENABLE_PRO_MIGRATION`: every route 404s while the flag is off, so
/// callers show a "not available yet" state (mirrors ProNoShowSettings).
/// PRO-only, owner-scoped server-side.
public final class ProMigrationService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/pro/migrate/summary → the migration wizard's read surface (the
    /// counts the entry + review screens show). Throws `APIError.server(404,…)`
    /// while `ENABLE_PRO_MIGRATION` is off (build-dark) → surface the
    /// "not available yet" state.
    public func summary() async throws -> ProMigrationSummary {
        let response: ProMigrationSummaryResponse = try await api.request("/pro/migrate/summary")
        return response.summary
    }

    /// POST /api/v1/pro/migrate/clients/preview → the dedupe preview for a set of
    /// raw CSV rows + column mapping. Read-only (no writes); `excludeIndices` is
    /// not sent (the route ignores it for preview). 404s while the flag is off.
    public func previewClientImport(
        rows: [[String: String]],
        mapping: ClientImportMapping
    ) async throws -> ClientImportPreviewResponse {
        let body = try JSONEncoder.canonical.encode(
            ClientImportRequestBody(rows: rows, mapping: mapping, excludeIndices: nil)
        )
        return try await api.request("/pro/migrate/clients/preview", method: .post, body: body)
    }

    /// POST /api/v1/pro/migrate/clients/commit → import the (non-excluded,
    /// importable) rows through the silent `upsertProClient` path, in one
    /// transaction. `excludeIndices` are the rows the pro deselected (plus the
    /// auto-excluded non-importable ones). 404s while the flag is off.
    public func commitClientImport(
        rows: [[String: String]],
        mapping: ClientImportMapping,
        excludeIndices: [Int]
    ) async throws -> ClientImportCommitResponse {
        let body = try JSONEncoder.canonical.encode(
            ClientImportRequestBody(rows: rows, mapping: mapping, excludeIndices: excludeIndices)
        )
        return try await api.request("/pro/migrate/clients/commit", method: .post, body: body)
    }

    // MARK: - Calendar import (increment 4)

    /// POST /api/v1/pro/migrate/calendar/fetch → pull a pro-supplied read-only
    /// calendar feed URL server-side (SSRF-guarded) and return the raw .ics text,
    /// so the feed-URL and file-upload paths converge on the same preview/commit.
    /// 404s while the flag is off.
    public func fetchCalendarFeed(url: String) async throws -> CalendarFeedFetchResponse {
        let body = try JSONEncoder.canonical.encode(CalendarFeedUrlRequestBody(url: url))
        return try await api.request("/pro/migrate/calendar/fetch", method: .post, body: body)
    }

    /// POST /api/v1/pro/migrate/calendar/preview → classify each event in the .ics
    /// against the pro's menu + clock (booking / blocked time / client history /
    /// skipped). Read-only (no writes); `excludeUids` is not sent (the route
    /// ignores it for preview). 404s while the flag is off.
    public func previewCalendarImport(ics: String) async throws -> CalendarImportPreviewResponse {
        let body = try JSONEncoder.canonical.encode(CalendarImportRequestBody(ics: ics, excludeUids: nil))
        return try await api.request("/pro/migrate/calendar/preview", method: .post, body: body)
    }

    /// POST /api/v1/pro/migrate/calendar/commit → materialize the (non-excluded)
    /// events through the shared, import-mode booking/client/block writes —
    /// silent (never messages a client). `excludeUids` are the rows the pro
    /// deselected. 404s while the flag is off.
    public func commitCalendarImport(
        ics: String,
        excludeUids: [String]
    ) async throws -> CalendarImportCommitResponse {
        let body = try JSONEncoder.canonical.encode(CalendarImportRequestBody(ics: ics, excludeUids: excludeUids))
        return try await api.request("/pro/migrate/calendar/commit", method: .post, body: body)
    }

    /// POST /api/v1/pro/migrate/calendar/subscription → connect (or update) a feed
    /// URL for auto-resync, so new bookings keep flowing while the pro finishes
    /// moving over. Only a feed-URL source can be kept in sync. 404s while the
    /// flag is off. Returns the saved subscription.
    @discardableResult
    public func connectCalendarSubscription(url: String) async throws -> CalendarFeedSubscription? {
        let body = try JSONEncoder.canonical.encode(CalendarFeedUrlRequestBody(url: url))
        let response: CalendarFeedSubscriptionResponse = try await api.request(
            "/pro/migrate/calendar/subscription", method: .post, body: body
        )
        return response.subscription
    }
}
