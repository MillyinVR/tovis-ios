import Foundation

/// PRO data-migration wizard — the native side of the web `/pro/migrate` flow.
/// Increment 1 covers the two RSC-only "bookend" screens (entry progress +
/// review/go-live summary), fed by `summary()`. Increment 2 adds the **clients
/// import** step — `previewClientImport` + `commitClientImport`, POSTing to the
/// existing web routes. The services + calendar steps are later increments.
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
}
