import Foundation

/// PRO data-migration wizard — the native read side of the web `/pro/migrate`
/// flow. Increment 1 covers the two RSC-only "bookend" screens: the entry
/// progress + the review/go-live summary, both fed by a single read route (the
/// same counts both web screens derive from `loadMigrationReviewSummary`). The
/// three working import steps (services / clients / calendar CSV+ICS upload,
/// preview, commit) are later increments.
///
/// Dark unless `ENABLE_PRO_MIGRATION`: the route 404s while the flag is off, so
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
}
