import Foundation

/// Reads + writes the messaging surface — the same endpoints the web inbox uses
/// (`/api/v1/messages/*`). Authenticated (bearer token).
public final class MessagesService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/messages/threads → the inbox list (newest first).
    public func threads() async throws -> [MessageThread] {
        let response: MessageThreadsResponse = try await api.request("/messages/threads")
        return response.threads
    }

    /// GET /api/v1/messages/threads/{id} → the latest page of messages (ascending).
    /// (v1 loads the most recent page; cursor paging can come later.)
    public func messages(threadId: String) async throws -> [Message] {
        let response: MessageThreadPageResponse = try await api.request("/messages/threads/\(threadId)")
        return response.messages
    }

    /// POST /api/v1/messages/threads/{id} → send a text message.
    public func send(threadId: String, body: String) async throws -> CreatedMessage {
        let payload = try JSONEncoder().encode(SendMessageRequest(body: body))
        let response: CreateMessageResponse = try await api.request(
            "/messages/threads/\(threadId)", method: .post, body: payload
        )
        return response.message
    }

    /// POST /api/v1/messages/threads/{id}/read → mark the thread read for me.
    public func markRead(threadId: String) async throws {
        try await api.requestVoid("/messages/threads/\(threadId)/read", method: .post)
    }

    /// GET /api/v1/messages/unread-count → unread thread count (for the badge).
    public func unreadCount() async throws -> Int {
        let response: UnreadCountResponse = try await api.request("/messages/unread-count")
        return response.count
    }
}