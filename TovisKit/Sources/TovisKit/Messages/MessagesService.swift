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
    ///
    /// Prefer `openProfileThread` / `openBookingThread` / `openClientThread` /
    /// `openWaitlistThread` when you need the thread itself — they keep the row
    /// the same call already returned instead of looking it up again.
    public func resolveThread(
        contextType: String,
        contextId: String,
        professionalId: String? = nil,
        clientId: String? = nil,
        createIfMissing: Bool = true
    ) async throws -> String? {
        try await resolveThreadRef(
            contextType: contextType,
            contextId: contextId,
            professionalId: professionalId,
            clientId: clientId,
            createIfMissing: createIfMissing
        )?.id
    }

    private func resolveThreadRef(
        contextType: String,
        contextId: String,
        professionalId: String?,
        clientId: String?,
        createIfMissing: Bool
    ) async throws -> ResolveThreadResponse.ResolvedThread? {
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
        return response.thread
    }

    /// Resolve-or-create a thread and return the full `MessageThread` to push
    /// into `ThreadView`. Shared by every `open*Thread` entry point below so the
    /// resolve → open sequence exists once.
    ///
    /// The row comes back on the resolve response itself. That matters most for
    /// a thread being created right now: it has no messages yet, and the inbox
    /// deliberately hides message-less threads, so the `thread(id:)` fallback
    /// below CANNOT find it — which is exactly why the first message to a client
    /// used to open nothing at all.
    private func openThread(
        contextType: String,
        contextId: String,
        professionalId: String? = nil,
        clientId: String? = nil
    ) async throws -> MessageThread? {
        guard let resolved = try await resolveThreadRef(
            contextType: contextType,
            contextId: contextId,
            professionalId: professionalId,
            clientId: clientId,
            createIfMissing: true
        ) else { return nil }

        if let row = resolved.row { return row }

        // Backend that predates the row on this response: fall back to the inbox
        // scan. Same behaviour as before — including its blind spot for a
        // brand-new thread, which no client-side workaround can close.
        return try await thread(id: resolved.id)
    }

    /// Look up a thread the viewer participates in by id, from the inbox list.
    ///
    /// ⚠️ Finds only threads that HAVE messages: the backend's inbox filter
    /// requires `lastMessageAt != null`, so a thread nobody has written in is
    /// absent from the list and this returns nil. Callers opening a thread they
    /// just resolved should use the `open*Thread` helpers, which take the row
    /// straight off the resolve response instead.
    public func thread(id: String) async throws -> MessageThread? {
        let all = try await threads()
        return all.first(where: { $0.id == id })
    }

    /// Resolve-or-create the thread for a pro's profile and return the full
    /// `MessageThread` so it can be pushed into `ThreadView`. Returns nil when no
    /// thread could be resolved. This is the CLIENT→pro direction (the client
    /// views a pro's profile).
    public func openProfileThread(professionalId: String) async throws -> MessageThread? {
        try await openThread(
            contextType: "PRO_PROFILE",
            contextId: professionalId,
            professionalId: professionalId
        )
    }

    /// Resolve-or-create the BOOKING-context thread and return the full
    /// `MessageThread`. Either party may open it (the backend authorizes the
    /// booking's client or pro); the pro booking-detail "Message" action uses it.
    public func openBookingThread(bookingId: String) async throws -> MessageThread? {
        try await openThread(contextType: "BOOKING", contextId: bookingId)
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
        try await openThread(
            contextType: "PRO_PROFILE",
            contextId: professionalId,
            clientId: clientId
        )
    }

    /// Resolve-or-create the WAITLIST-context thread for a waitlist entry and
    /// return the full `MessageThread` so it can be pushed into `ThreadView`. The
    /// backend derives the client & pro from the entry (viewer must be its pro or
    /// client), so only the entry id is needed — mirrors web's
    /// `/messages/start?contextType=WAITLIST&contextId=…`. Used by the pro
    /// waitlist-outreach "Message" action.
    public func openWaitlistThread(waitlistEntryId: String) async throws -> MessageThread? {
        try await openThread(contextType: "WAITLIST", contextId: waitlistEntryId)
    }
}

struct ResolveThreadResponse: Decodable, Sendable {
    let thread: ResolvedThread?

    /// The `thread` object on a resolve response. Always carries `id`; carries
    /// the whole inbox row too once the backend serializes it.
    struct ResolvedThread: Decodable, Sendable {
        let id: String
        /// The full row, or nil against a backend that answers `{"id":"…"}`
        /// alone. Absent means "look it up the old way", never a decode failure —
        /// the app must keep working against the currently deployed API.
        let row: MessageThread?

        private enum CodingKeys: String, CodingKey { case id }

        init(from decoder: any Decoder) throws {
            // `id` is the contract and must decode; the row is probed off the
            // SAME object. `try?` is a shape test on a body already in hand, not
            // a swallowed network error — a failure here means "older backend".
            id = try decoder.container(keyedBy: CodingKeys.self).decode(
                String.self, forKey: .id
            )
            row = try? MessageThread(from: decoder)
        }
    }
}