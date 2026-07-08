import Foundation

// Wire models for messaging — GET /api/v1/messages/threads,
// GET/POST /api/v1/messages/threads/{id}, POST .../read,
// GET /api/v1/messages/unread-count. Mirrors lib/dto/messaging.ts. Only the
// rendered subset is modeled; nullable fields are optionals; unknown keys ignored.

// MARK: - Thread list

/// Inbox filter tab — mirrors the web inbox's tabs and the `?filter=` query the
/// backend accepts on GET /api/v1/messages/threads. Server-side filtering keeps
/// the native app and the web page returning the same set.
public enum InboxFilter: String, Sendable, CaseIterable, Identifiable {
    case all, bookings, waitlists, pros

    public var id: String { rawValue }

    /// Tab label shown in the inbox filter bar.
    public var label: String {
        switch self {
        case .all: return "All"
        case .bookings: return "Bookings"
        case .waitlists: return "Waitlists"
        case .pros: return "Pros"
        }
    }
}

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
    /// Whether the viewer is this thread's professional — derived server-side from
    /// the viewer's user id (dual-role/admin safe), NOT the app's acting tab. The
    /// counterparty is the client when true, the pro when false. This is the only
    /// signal the list payload carries for picking whose name/avatar to show.
    public let isViewerPro: Bool
    /// Server-computed context label for the row (booking time / waitlist status /
    /// service name), e.g. "BOOKING CONFIRMED — Balayage — Fri 2:00 PM". Rendered
    /// verbatim so a new backend context type never fails to display. Optional so
    /// pre-field fixtures/cached responses still decode; the live API always sends it.
    public let eyebrow: String?
    /// Whether `eyebrow` renders in the accent tone (actionable context — booking /
    /// offering / waitlist). Optional for the same back-compat reason.
    public let isAccentContext: Bool?

    /// Unread for me when the last message is newer than my last-read stamp.
    /// Both are backend `toISOString()` values, so lexical compare == chronological.
    public var isUnread: Bool {
        guard let last = lastMessageAt else { return false }
        guard let mine = participants.first?.lastReadAt else { return true }
        return last > mine
    }

    /// The other party's display name — client to a pro, pro to a client.
    public var counterpartyName: String {
        isViewerPro ? client.displayName : professional.displayName
    }

    /// The other party's avatar url — client to a pro, pro to a client.
    public var counterpartyAvatarUrl: String? {
        isViewerPro ? client.avatarUrl : professional.avatarUrl
    }
}

public struct MessageClientPreview: Decodable, Sendable, Identifiable {
    public let id: String
    public let firstName: String?
    public let lastName: String?
    public let avatarUrl: String?

    /// First + last, trimmed; falls back to "Client" (matches web `formatPersonName`
    /// with the 'Client' fallback in resolveThreadCounterparty).
    public var displayName: String {
        let name = [firstName, lastName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? "Client" : name
    }
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
    /// Optional so pre-field fixtures still decode; the live API always sends it.
    let thread: MessageThreadPageThread?
    let messages: [Message]
    let nextCursor: String?
    let hasMore: Bool
    let take: Int
}

/// The thread envelope on GET /messages/threads/{id} — carries the viewer role
/// and the counterparty's read stamp (for the sender's read receipt).
public struct MessageThreadPageThread: Decodable, Sendable {
    public let id: String
    public let isViewerPro: Bool
    /// The other party's last-read timestamp (ISO-8601), or nil if unread. An
    /// outgoing message is "Read" once this is >= its createdAt.
    public let counterpartyLastReadAt: String?
}

/// Service-facing result of fetching a thread's messages: the page, the
/// counterparty read stamp that drives the sender's read receipt, and the
/// cursor for the next-older page (`nextCursor`/`hasMore`) used by "load earlier".
public struct MessageThreadPage: Sendable {
    public let messages: [Message]
    public let counterpartyLastReadAt: String?
    /// Cursor for the next-older page (oldest message id in this page), or nil at
    /// the start of history. Pass it back as `cursor:` to page backwards.
    public let nextCursor: String?
    /// Whether there are older messages to load.
    public let hasMore: Bool

    public init(
        messages: [Message],
        counterpartyLastReadAt: String?,
        nextCursor: String? = nil,
        hasMore: Bool = false
    ) {
        self.messages = messages
        self.counterpartyLastReadAt = counterpartyLastReadAt
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
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
    /// media-private storage paths (from POST .../uploads) to attach. `nil` when
    /// there are none, so the encoded body stays byte-identical for text-only
    /// sends (synthesized `encodeIfPresent` omits the key).
    let attachments: [String]?

    init(body: String, attachments: [String]? = nil) {
        self.body = body
        self.attachments = attachments
    }
}

struct CreateMessageResponse: Decodable, Sendable {
    let message: CreatedMessage
}

public struct CreatedMessage: Decodable, Sendable, Identifiable {
    public let id: String
    public let body: String?
    public let createdAt: String
    public let senderUserId: String
    /// The message's attachments, with freshly-signed render URLs — so an image
    /// message renders immediately without waiting for the next poll. Optional so
    /// pre-field fixtures still decode; the live API always sends it.
    public let attachments: [MessageAttachment]?
}

// MARK: - Attachment upload

/// POST /api/v1/messages/threads/{id}/uploads response — a presigned,
/// thread-scoped, media-private upload target for a message image attachment.
public struct MessageUploadInit: Decodable, Sendable {
    public let bucket: String
    public let path: String
    public let token: String
    public let signedUrl: String?
}

struct MessageUploadInitRequest: Encodable, Sendable {
    let contentType: String
    let size: Int
}

// MARK: - Unread count

struct UnreadCountResponse: Decodable, Sendable {
    let count: Int
    let badge: String?
}