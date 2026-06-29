import Foundation

/// PRO notification center (web `/pro/notifications`) — a DISTINCT surface from the
/// client center. Reads the feed + unread summary, marks read (one / all), and
/// reads/writes preferences (the shared `NotificationPreferences` payload, on the
/// pro endpoints). Authenticated; PRO-only. See docs/PRO-BACKEND-CONTRACTS.md.
public final class ProNotificationsService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    public struct FeedPage: Sendable {
        public let items: [ProNotification]
        public let nextCursor: String?
    }

    /// GET /api/v1/pro/notifications. `cursor` pages; `unreadOnly`/`eventKey` filter.
    public func feed(
        unreadOnly: Bool = false,
        eventKey: String? = nil,
        cursor: String? = nil,
        take: Int = 50
    ) async throws -> FeedPage {
        var query = [URLQueryItem(name: "take", value: String(take))]
        if unreadOnly { query.append(URLQueryItem(name: "unread", value: "true")) }
        if let eventKey { query.append(URLQueryItem(name: "eventKey", value: eventKey)) }
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }

        let response: ProNotificationListResponse =
            try await api.request("/pro/notifications", query: query)
        return FeedPage(items: response.items, nextCursor: response.nextCursor)
    }

    /// GET /api/v1/pro/notifications/summary — `{ hasUnread, count }` for the bell.
    public func summary() async throws -> ProNotificationSummary {
        try await api.request("/pro/notifications/summary")
    }

    /// POST /api/v1/pro/notifications/{id}/mark-read. Idempotent.
    public func markRead(id: String) async throws {
        try await api.requestVoid("/pro/notifications/\(id)/mark-read", method: .post)
    }

    /// POST /api/v1/pro/notifications/mark-read — mark everything read; returns the
    /// number of rows updated.
    @discardableResult
    public func markAllRead() async throws -> Int {
        let response: ProNotificationsMarkAllResponse =
            try await api.request("/pro/notifications/mark-read", method: .post)
        return response.count ?? 0
    }

    /// GET /api/v1/pro/notification-preferences — shared preferences payload.
    public func preferences() async throws -> NotificationPreferences {
        try await api.request("/pro/notification-preferences")
    }

    /// PATCH /api/v1/pro/notification-preferences — persist channel toggles + quiet
    /// hours; returns the re-read preferences.
    @discardableResult
    public func updatePreferences(
        events: [String: NotificationChannelPreference],
        quietHours: NotificationQuietHours
    ) async throws -> NotificationPreferences {
        let body = try JSONEncoder().encode(
            NotificationPreferencesUpdateRequest(events: events, quietHours: quietHours)
        )
        return try await api.request(
            "/pro/notification-preferences", method: .patch, body: body
        )
    }
}
