import Foundation

/// The client "Activity" feed — the creator-engagement surface, distinct from
/// the transactional notification centre `NotificationsService` reads.
/// Authenticated, CLIENT-only.
///
/// Reads only. The two writes an activity row offers are already owned by their
/// domain services and are reused rather than re-wrapped here:
///   • follow-back  → `PublicClientService.toggleFollow(handle:)`
///   • mark-all-read → `NotificationsService.markRead(eventKeys:)`, handed the
///     server's own `markReadEventKeys` allowlist so the app never hard-codes
///     which events count as "activity".
public final class ActivityService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/client/activity — the JSON twin of web's /client/activity page
    /// (both read the same loader). Unpaginated, matching web: the backend caps
    /// the feed at its own default take.
    public func feed() async throws -> ClientActivityFeed {
        let response: ClientActivityResponse = try await api.request("/client/activity")
        return response.activity
    }
}
