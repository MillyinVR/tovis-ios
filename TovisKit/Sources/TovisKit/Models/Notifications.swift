import Foundation

// Wire models for the client notification surface — GET /api/v1/client/notifications,
// GET .../summary, POST .../read, GET/PATCH /api/v1/client/notification-preferences.
// Mirrors lib/dto/clientNotifications.ts + the notification-preferences payload
// (lib/notifications/preferenceService). Only the rendered subset is modeled;
// nullable fields are optionals; unknown keys (e.g. the arbitrary `data` blob and
// the response envelope's `ok`) are ignored by Decodable.

// MARK: - Feed

struct ClientNotificationListResponse: Decodable, Sendable {
    let items: [ClientNotification]
    let nextCursor: String?
    // `filters` is echoed back by the route but not needed by the client.
}

public struct ClientNotification: Decodable, Sendable, Identifiable {
    public let id: String
    /// A `NotificationEventKey` value (e.g. "BOOKING_CONFIRMED"). Kept as a raw
    /// string so a new backend event never fails decoding.
    public let eventKey: String
    public let title: String
    public let body: String?
    /// Internal deep-link path (e.g. "/client/bookings/bk_1"); "" when none.
    public let href: String
    public let createdAt: String
    public let updatedAt: String
    /// ISO instant when the client read it; nil while unread.
    public let readAt: String?
    public let bookingId: String?
    public let aftercareId: String?

    public var isUnread: Bool { readAt == nil }
}

// MARK: - Summary (drives the unread bell badge)

public struct ClientNotificationSummary: Decodable, Sendable {
    public let pendingUnreadCount: Int
    public let aftercareUnreadCount: Int
    public let upcomingUnreadCount: Int
    public let hasAnyUnreadUpdates: Bool
}

// MARK: - Mark read

struct MarkNotificationsReadRequest: Encodable, Sendable {
    // Optionals are omitted from the JSON when nil (synthesized `encodeIfPresent`),
    // so the route receives only the selector the caller intends.
    let ids: [String]?
    let eventKeys: [String]?
    let before: String?
}

struct ClientNotificationsReadResponse: Decodable, Sendable {
    let count: Int
}

// MARK: - Preferences (GET/PATCH /api/v1/client/notification-preferences)

public struct NotificationChannelPreference: Codable, Sendable, Equatable {
    public let inAppEnabled: Bool
    public let smsEnabled: Bool
    public let emailEnabled: Bool

    public init(inAppEnabled: Bool, smsEnabled: Bool, emailEnabled: Bool) {
        self.inAppEnabled = inAppEnabled
        self.smsEnabled = smsEnabled
        self.emailEnabled = emailEnabled
    }
}

public struct NotificationQuietHours: Codable, Sendable, Equatable {
    public let enabled: Bool
    /// Minutes-of-day [0, 1439]. Equal start/end means "off" (the engine sentinel).
    public let startMinutes: Int
    public let endMinutes: Int

    public init(enabled: Bool, startMinutes: Int, endMinutes: Int) {
        self.enabled = enabled
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }
}

public struct NotificationCategoryEvent: Decodable, Sendable, Identifiable {
    public let eventKey: String
    public let label: String
    /// Channels this event can use ("IN_APP" / "SMS" / "EMAIL") — the only toggles shown.
    public let supportedChannels: [String]
    /// When true the EMAIL toggle is locked on (critical event the engine always emails).
    public let emailLocked: Bool

    public var id: String { eventKey }
}

public struct NotificationCategory: Decodable, Sendable, Identifiable {
    public let key: String
    public let label: String
    public let description: String
    public let events: [NotificationCategoryEvent]

    public var id: String { key }
}

public struct NotificationPreferences: Decodable, Sendable {
    public let categories: [NotificationCategory]
    /// Effective per-event channel state, keyed by event key.
    public let events: [String: NotificationChannelPreference]
    public let quietHours: NotificationQuietHours
}

struct NotificationPreferencesUpdateRequest: Encodable, Sendable {
    let events: [String: NotificationChannelPreference]
    let quietHours: NotificationQuietHours
}
