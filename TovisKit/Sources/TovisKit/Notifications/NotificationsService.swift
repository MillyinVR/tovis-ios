import Foundation

/// The client notification center — the same endpoints the backend exposes for
/// the web client (`/api/v1/client/notifications*` + `/notification-preferences`).
/// Authenticated, CLIENT-only. Reads the feed + unread summary, marks read, and
/// reads/writes per-channel preferences + quiet hours.
public final class NotificationsService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// A page of the feed plus the opaque cursor for the next page (nil = end).
    public struct FeedPage: Sendable {
        public let items: [ClientNotification]
        public let nextCursor: String?
    }

    /// GET /api/v1/client/notifications. `cursor` is the prior page's `nextCursor`;
    /// `unreadOnly` filters to unread; `eventKey` filters to one event type.
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

        let response: ClientNotificationListResponse =
            try await api.request("/client/notifications", query: query)
        return FeedPage(items: response.items, nextCursor: response.nextCursor)
    }

    /// GET /api/v1/client/notifications/summary — bucketed unread counts that
    /// drive the bell badge (`hasAnyUnreadUpdates` for a dot).
    public func summary() async throws -> ClientNotificationSummary {
        try await api.request("/client/notifications/summary")
    }

    /// POST /api/v1/client/notifications/read — mark read by `ids`, by
    /// `eventKeys`, and/or everything created at/before `before` (ISO). With no
    /// selector the backend marks all of the client's notifications read.
    /// Returns the number of rows updated. Idempotent.
    @discardableResult
    public func markRead(
        ids: [String]? = nil,
        eventKeys: [String]? = nil,
        before: String? = nil
    ) async throws -> Int {
        let body = try JSONEncoder().encode(
            MarkNotificationsReadRequest(ids: ids, eventKeys: eventKeys, before: before)
        )
        let response: ClientNotificationsReadResponse =
            try await api.request("/client/notifications/read", method: .post, body: body)
        return response.count
    }

    /// GET /api/v1/client/notification-preferences — categories + per-event
    /// channel state + quiet hours.
    public func preferences() async throws -> NotificationPreferences {
        try await api.request("/client/notification-preferences")
    }

    /// PATCH /api/v1/client/notification-preferences — persist channel toggles +
    /// quiet hours. Returns the re-read preferences. Only event keys the client
    /// can manage are accepted; the engine still enforces email-locked events.
    @discardableResult
    public func updatePreferences(
        events: [String: NotificationChannelPreference],
        quietHours: NotificationQuietHours
    ) async throws -> NotificationPreferences {
        let body = try JSONEncoder().encode(
            NotificationPreferencesUpdateRequest(events: events, quietHours: quietHours)
        )
        return try await api.request(
            "/client/notification-preferences", method: .patch, body: body
        )
    }
}
