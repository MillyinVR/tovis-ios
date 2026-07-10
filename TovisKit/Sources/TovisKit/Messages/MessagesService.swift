import Foundation

/// Reads + writes the messaging surface — the same endpoints the web inbox uses
/// (`/api/v1/messages/*`). Authenticated (bearer token).
public final class MessagesService: Sendable {
    private let api: APIClient
    /// Supabase project URL + publishable key — the same public creds the signed
    /// storage PUT uses (nil disables attachment uploads).
    private let supabaseURL: URL?
    private let supabaseKey: String?
    /// Ephemeral (no cookie jar) so the storage PUT stays clean.
    private let uploadSession: URLSession

    public init(api: APIClient, supabaseURL: URL? = nil, supabaseKey: String? = nil) {
        self.api = api
        self.supabaseURL = supabaseURL
        self.supabaseKey = supabaseKey
        self.uploadSession = URLSession(configuration: .ephemeral)
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

    /// POST /api/v1/messages/threads/{id} → send a message. `attachmentPaths` are
    /// media-private storage paths already uploaded via `uploadAttachment`; the
    /// message needs text or at least one attachment.
    public func send(
        threadId: String,
        body: String,
        attachmentPaths: [String] = []
    ) async throws -> CreatedMessage {
        let payload = try JSONEncoder.canonical.encode(
            SendMessageRequest(
                body: body,
                attachments: attachmentPaths.isEmpty ? nil : attachmentPaths
            )
        )
        let response: CreateMessageResponse = try await api.request(
            "/messages/threads/\(threadId)", method: .post, body: payload
        )
        return response.message
    }

    /// Presign → signed PUT an image to media-private for this thread, returning
    /// the storage path to hand to `send(threadId:body:attachmentPaths:)`. Reuses
    /// the shared RLS-critical signed PUT (`SupabaseSignedUpload`).
    public func uploadAttachment(
        threadId: String,
        imageData: Data,
        contentType: String = "image/jpeg"
    ) async throws -> String {
        let initData = try await presignAttachment(
            threadId: threadId, contentType: contentType, size: imageData.count
        )
        try await SupabaseSignedUpload.put(
            session: uploadSession,
            supabaseURL: supabaseURL,
            supabaseKey: supabaseKey,
            data: imageData,
            bucket: initData.bucket,
            path: initData.path,
            token: initData.token,
            contentType: contentType,
            upsert: false
        )
        return initData.path
    }

    /// POST /api/v1/messages/threads/{id}/uploads → a presigned media-private
    /// upload target scoped to this thread.
    public func presignAttachment(
        threadId: String,
        contentType: String,
        size: Int
    ) async throws -> MessageUploadInit {
        let payload = try JSONEncoder.canonical.encode(
            MessageUploadInitRequest(contentType: contentType, size: size)
        )
        return try await api.request(
            "/messages/threads/\(threadId)/uploads", method: .post, body: payload
        )
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

        let payload = try JSONEncoder.canonical.encode(fields)
        let response: ResolveThreadResponse = try await api.request(
            "/messages/resolve", method: .post, body: payload
        )
        return response.thread?.id
    }

    /// Look up a thread the viewer participates in by id, from the inbox list.
    /// A deep-linked / just-resolved thread is always in the viewer's inbox (they
    /// participate) and bubbles to the top by `lastMessageAt`, so the first page
    /// finds it — the same "find in the list" approach `openProfileThread` uses
    /// (there's no standalone GET thread-metadata endpoint).
    public func thread(id: String) async throws -> MessageThread? {
        let all = try await threads()
        return all.first(where: { $0.id == id })
    }

    /// Resolve-or-create the thread for a pro's profile and return the full
    /// `MessageThread` (found in the inbox list) so it can be pushed into
    /// `ThreadView`. Returns nil when no thread could be resolved. This is the
    /// CLIENT→pro direction (the client views a pro's profile).
    public func openProfileThread(professionalId: String) async throws -> MessageThread? {
        guard let threadId = try await resolveThread(
            contextType: "PRO_PROFILE",
            contextId: professionalId,
            professionalId: professionalId,
            createIfMissing: true
        ) else { return nil }

        return try await thread(id: threadId)
    }

    /// Resolve-or-create the BOOKING-context thread and return the full
    /// `MessageThread`. Either party may open it (the backend authorizes the
    /// booking's client or pro); the pro booking-detail "Message" action uses it.
    public func openBookingThread(bookingId: String) async throws -> MessageThread? {
        guard let threadId = try await resolveThread(
            contextType: "BOOKING",
            contextId: bookingId,
            createIfMissing: true
        ) else { return nil }

        return try await thread(id: threadId)
    }

    /// Resolve-or-create the general pro↔client thread (PRO_PROFILE context, from
    /// the PRO side) and return the full `MessageThread`. This mirrors
    /// `openProfileThread` for the opposite direction: `professionalId` is the
    /// pro's OWN profile id (the backend requires `contextId == viewer's
    /// professionalId`) and `clientId` names the client to converse with. Used by
    /// the pro client-chart "Message" action, which has no booking to anchor to.
    public func openClientThread(
        professionalId: String,
        clientId: String
    ) async throws -> MessageThread? {
        guard let threadId = try await resolveThread(
            contextType: "PRO_PROFILE",
            contextId: professionalId,
            clientId: clientId,
            createIfMissing: true
        ) else { return nil }

        return try await thread(id: threadId)
    }
}

private struct ResolveThreadResponse: Decodable, Sendable {
    let thread: ThreadRef?

    struct ThreadRef: Decodable, Sendable {
        let id: String
    }
}