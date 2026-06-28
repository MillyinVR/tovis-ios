import Foundation

// Wire models for messaging — GET /api/v1/messages/threads,
// GET/POST /api/v1/messages/threads/{id}, POST .../read,
// GET /api/v1/messages/unread-count. Mirrors lib/dto/messaging.ts. Only the
// rendered subset is modeled; nullable fields are optionals; unknown keys ignored.

// MARK: - Thread list

struct MessageThreadsResponse: Decodable, Sendable {
    let threads: [MessageThread]
}

public struct MessageThread: Decodable, Sendable, Identifiable {
    public let id: String
    public let contextType: String?
    public let bookingId: String?
    public let lastMessageAt: String?
    public let lastMessagePreview: String?
    public let updatedAt: String
    public let client: MessageClientPreview
    public let professional: MessageProPreview
    /// Scoped to the current user by the backend, so `first` is *my* read state.
    public let participants: [MessageParticipantRead]

    /// Unread for me when the last message is newer than my last-read stamp.
    /// Both are backend `toISOString()` values, so lexical compare == chronological.
    public var isUnread: Bool {
        guard let last = lastMessageAt else { return false }
        guard let mine = participants.first?.lastReadAt else { return true }
        return last > mine
    }
}

public struct MessageClientPreview: Decodable, Sendable, Identifiable {
    public let id: String
    public let firstName: String?
    public let lastName: String?
    public let avatarUrl: String?
}

public struct MessageProPreview: Decodable, Sendable, Identifiable {
    public let id: String
    public let businessName: String?
    public let avatarUrl: String?

    public var displayName: String {
        let name = businessName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Your pro" : name
    }
}

public struct MessageParticipantRead: Decodable, Sendable {
    public let lastReadAt: String?
}

// MARK: - Thread messages

struct MessageThreadPageResponse: Decodable, Sendable {
    let messages: [Message]
    let nextCursor: String?
    let hasMore: Bool
    let take: Int
}

public struct Message: Decodable, Sendable, Identifiable {
    public let id: String
    public let body: String?
    public let createdAt: String
    public let senderUserId: String
    public let attachments: [MessageAttachment]
}

public struct MessageAttachment: Decodable, Sendable, Identifiable {
    public let id: String
    public let url: String
    public let mediaType: String?
}

// MARK: - Send

struct SendMessageRequest: Encodable, Sendable {
    let body: String
}

struct CreateMessageResponse: Decodable, Sendable {
    let message: CreatedMessage
}

public struct CreatedMessage: Decodable, Sendable, Identifiable {
    public let id: String
    public let body: String?
    public let createdAt: String
    public let senderUserId: String
}

// MARK: - Unread count

struct UnreadCountResponse: Decodable, Sendable {
    let count: Int
    let badge: String?
}