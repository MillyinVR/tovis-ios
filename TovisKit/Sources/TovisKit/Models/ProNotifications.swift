import Foundation

// Wire models for the PRO notification surface — GET /api/v1/pro/notifications,
// GET .../summary, POST .../[id]/mark-read, POST .../mark-read. This is a DISTINCT
// surface from the client center (different table/fields: priority + seenAt +
// reviewId). Preferences reuse the shared `NotificationPreferences` payload (the
// pro just has a different category set). See docs/PRO-BACKEND-CONTRACTS.md.

struct ProNotificationListResponse: Decodable, Sendable {
    let items: [ProNotification]
    let nextCursor: String?
}

public struct ProNotification: Decodable, Sendable, Identifiable {
    public let id: String
    /// A `NotificationEventKey` (kept raw so a new backend event never breaks decoding).
    public let eventKey: String
    public let priority: Int?
    public let title: String
    public let body: String?
    /// Internal deep-link path (e.g. "/pro/bookings/bk_1"); may be "".
    public let href: String
    public let createdAt: String
    public let seenAt: String?
    public let readAt: String?
    public let bookingId: String?
    public let reviewId: String?

    public var isUnread: Bool { readAt == nil }
}

/// GET /api/v1/pro/notifications/summary — drives the bell badge.
public struct ProNotificationSummary: Decodable, Sendable {
    public let hasUnread: Bool
    public let count: Int
}

struct ProNotificationsMarkAllResponse: Decodable, Sendable {
    let count: Int?
}
