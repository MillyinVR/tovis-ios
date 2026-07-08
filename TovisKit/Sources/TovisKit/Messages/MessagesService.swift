import Foundation

/// Reads + writes the messaging surface — the same endpoints the web inbox uses
/// (`/api/v1/messages/*`). Authenticated (bearer token).
public final class MessagesService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    /// GET /api/v1/messages/threads → the inbox list (newest first), optionally
    /// scoped to a filter tab. `.all` sends no query param (backend defaults to
    /// all), so the byte shape is unchanged for existing callers.
    public func threads(filter: InboxFilter = .all) async throws -> [MessageThread] {
        let query = filter == .all ? nil : [URLQueryItem(name: "filter", value: filter.rawValue)]
        let response: MessageThreadsResponse = try await api.request("/messages/threads", query: query)
        return response.threads
    }

    /// GET /api/v1/messages/threads/{id} → a page of messages (ascending) plus the
    /// counterparty's last-read stamp for the sender's read receipt. With no
    /// `cursor` this is the most recent page; pass a page's `nextCursor` to load
    /// the messages older than it ("load earlier"). The returned `nextCursor` /
    /// `hasMore` describe whether there's still older history to page through.
    public func messages(threadId: String, cursor: String? = nil) async throws -> MessageThreadPage {
        let query = cursor.map { [URLQueryItem(name: "cursor", value: $0)] }
        let response: MessageThreadPageResponse = try await api.request(
            "/messages/threads/\(threadId)", query: query
        )
        return MessageThreadPage(
            messages: response.messages,
            counterpartyLastReadAt: response.thread?.counterpartyLastReadAt,
            nextCursor: response.nextCursor,
            hasMore: response.hasMore
        )
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

    /// POST /api/v1/messages/resolve → find-or-create the thread for a context
    /// (e.g. a pro's profile) and return its id, or nil if none resolved. The
    /// same endpoint the web "Message" button uses.
    public func resolveThread(
        contextType: String,
        contextId: String,
        professionalId: String? = nil,
        clientId: String? = nil,
        createIfMissing: Bool = true
    ) async throws -> String? {
        var fields: [String: JSONValue] = [
            "contextType": .string(contextType),
            "contextId": .string(contextId),
            "createIfMissing": .bool(createIfMissing),
        ]
        if let professionalId { fields["professionalId"] = .string(professionalId) }
        if let clientId { fields["clientId"] = .string(clientId) }

        let payload = try JSONEncoder().encode(fields)
        let response: ResolveThreadResponse = try await api.request(
            "/messages/resolve", method: .post, body: payload
        )
        return response.thread?.id
    }

    /// Resolve-or-create the thread for a pro's profile and return the full
    /// `MessageThread` (found in the inbox list) so it can be pushed into
    /// `ThreadView`. Returns nil when no thread could be resolved.
    public func openProfileThread(professionalId: String) async throws -> MessageThread? {
        guard let threadId = try await resolveThread(
            contextType: "PRO_PROFILE",
            contextId: professionalId,
            professionalId: professionalId,
            createIfMissing: true
        ) else { return nil }

        let all = try await threads()
        return all.first(where: { $0.id == threadId })
    }
}

private struct ResolveThreadResponse: Decodable, Sendable {
    let thread: ThreadRef?

    struct ThreadRef: Decodable, Sendable {
        let id: String
    }
}