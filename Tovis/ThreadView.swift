// A single conversation — GET /api/v1/messages/threads/{id} + POST to send, and
// POST .../read to clear unread. Native rebuild of the web thread view: chat
// bubbles (mine right/accent, theirs left/surface) with a pinned composer, day
// separators, read receipts, and optimistic send with retry.
import SwiftUI
import TovisKit

/// A message as rendered in the thread: a server message, or a locally-created
/// (optimistic) one the server hasn't acked yet. `clientId` correlates an
/// optimistic row with its eventual server message so a poll never duplicates it.
private struct ThreadMessage: Identifiable {
    enum Status { case sent, sending, failed }

    let id: String
    let clientId: String?
    let body: String?
    let createdAt: String
    let senderUserId: String
    let attachments: [MessageAttachment]
    var status: Status

    init(server: Message) {
        id = server.id
        clientId = nil
        body = server.body
        createdAt = server.createdAt
        senderUserId = server.senderUserId
        attachments = server.attachments
        status = .sent
    }

    init(created: CreatedMessage) {
        id = created.id
        clientId = nil
        body = created.body
        createdAt = created.createdAt
        senderUserId = created.senderUserId
        attachments = []
        status = .sent
    }

    init(optimistic clientId: String, body: String, senderUserId: String, createdAt: String) {
        id = clientId
        self.clientId = clientId
        self.body = body
        self.createdAt = createdAt
        self.senderUserId = senderUserId
        attachments = []
        status = .sending
    }
}

struct ThreadView: View {
    @Environment(SessionModel.self) private var session
    let thread: MessageThread

    @State private var messages: [ThreadMessage] = []
    @State private var counterpartyLastReadAt: String?
    @State private var myUserId: String?
    @State private var draft: String = ""
    @State private var loaded = false
    @State private var sending = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if showDaySeparator(at: index) {
                            DaySeparator(label: dayLabel(message.createdAt))
                        }
                        MessageBubble(
                            message: message,
                            isMine: message.senderUserId == myUserId,
                            isRead: message.id == lastReadMineId,
                            onRetry: { Task { await retry(message) } }
                        )
                        .id(message.id)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .onChange(of: messages.count) { scrollToBottom(proxy) }
            .task {
                myUserId = await session.client.currentUserId()
                if !loaded { await load(scroll: proxy) }
            }
            .onChange(of: session.refreshTick) { Task { await load(scroll: proxy) } }
            .task { await poll(proxy) }
        }
        .navigationTitle(thread.counterpartyName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .safeAreaInset(edge: .bottom) { composer }
        .tint(BrandColor.accent)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let errorMessage {
                Text(errorMessage).font(BrandFont.body(11.5)).foregroundStyle(BrandColor.ember)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message…", text: $draft, axis: .vertical)
                    .font(BrandFont.body(15))
                    .foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(BrandColor.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))

                Button { Task { await send() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(BrandColor.onAccent)
                        .frame(width: 38, height: 38)
                        .background(canSend ? BrandColor.accent : BrandColor.textMuted.opacity(0.4))
                        .clipShape(Circle())
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(BrandColor.bgPrimary)
    }

    private var canSend: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The last of my sent messages the counterparty has read — the only one that
    /// shows a "Read" receipt. Both stamps are backend `toISOString()` values, so
    /// a lexical compare is chronological.
    private var lastReadMineId: String? {
        guard let readAt = counterpartyLastReadAt, let mine = myUserId else { return nil }
        var id: String?
        for message in messages where message.senderUserId == mine && message.status == .sent {
            if message.createdAt <= readAt { id = message.id }
        }
        return id
    }

    private func showDaySeparator(at index: Int) -> Bool {
        guard index < messages.count else { return false }
        if index == 0 { return true }
        return !sameDay(messages[index - 1].createdAt, messages[index].createdAt)
    }

    private let bottomAnchor = "thread-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
    }

    private func poll(_ proxy: ScrollViewProxy) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { await load(scroll: proxy) }
        }
    }

    private func load(scroll proxy: ScrollViewProxy? = nil) async {
        do {
            let page = try await session.client.messages.messages(threadId: thread.id)
            applyServer(page)
            loaded = true
            try? await session.client.messages.markRead(threadId: thread.id)
            if let proxy { scrollToBottom(proxy) }
        } catch let error as APIError {
            if !loaded { errorMessage = error.userMessage }
        } catch {
            if !loaded { errorMessage = "Couldn’t load this conversation." }
        }
    }

    /// Merge a fresh server page over local state, preserving any optimistic
    /// (sending/failed) rows the server doesn't know about yet.
    private func applyServer(_ page: MessageThreadPage) {
        counterpartyLastReadAt = page.counterpartyLastReadAt
        let pending = messages.filter { $0.status != .sent }
        messages = page.messages.map(ThreadMessage.init(server:)) + pending
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, let mine = myUserId else { return }

        let clientId = UUID().uuidString
        messages.append(ThreadMessage(
            optimistic: clientId, body: text, senderUserId: mine, createdAt: Wire.nowISO()
        ))
        draft = ""
        errorMessage = nil
        sending = true
        await post(text, clientId: clientId)
        sending = false
    }

    private func retry(_ message: ThreadMessage) async {
        guard let clientId = message.clientId, let body = message.body else { return }
        setStatus(clientId: clientId, to: .sending)
        errorMessage = nil
        await post(body, clientId: clientId)
    }

    /// Send one body; swap the optimistic row for the server message on success,
    /// mark it failed on error.
    private func post(_ text: String, clientId: String) async {
        do {
            let created = try await session.client.messages.send(threadId: thread.id, body: text)
            messages = messages
                .filter { $0.clientId != clientId && $0.id != created.id }
                + [ThreadMessage(created: created)]
            try? await session.client.messages.markRead(threadId: thread.id)
        } catch let error as APIError {
            errorMessage = error.userMessage
            setStatus(clientId: clientId, to: .failed)
        } catch {
            errorMessage = "Couldn’t send. Try again."
            setStatus(clientId: clientId, to: .failed)
        }
    }

    private func setStatus(clientId: String, to status: ThreadMessage.Status) {
        messages = messages.map {
            guard $0.clientId == clientId else { return $0 }
            var next = $0
            next.status = status
            return next
        }
    }

    // MARK: - Day grouping

    private func sameDay(_ a: String, _ b: String) -> Bool {
        guard let da = Wire.date(a), let db = Wire.date(b) else { return false }
        return Calendar.current.isDate(da, inSameDayAs: db)
    }

    private func dayLabel(_ iso: String) -> String {
        guard let date = Wire.date(iso) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = cal.isDate(date, equalTo: Date(), toGranularity: .year)
            ? "EEE, MMM d"
            : "MMM d, yyyy"
        return f.string(from: date)
    }
}

private struct DaySeparator: View {
    let label: String
    var body: some View {
        Text(label)
            .font(BrandFont.mono(9)).tracking(0.6)
            .foregroundStyle(BrandColor.textMuted)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(BrandColor.bgSurface)
            .clipShape(Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

private struct MessageBubble: View {
    let message: ThreadMessage
    let isMine: Bool
    let isRead: Bool
    let onRetry: () -> Void

    @State private var viewingMedia: FullscreenMedia?

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 40) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
                ForEach(message.attachments) { att in
                    if let url = URL(string: att.url) {
                        let isVideo = att.mediaType?.uppercased() == "VIDEO"
                        Button {
                            viewingMedia = FullscreenMedia.remote(id: att.id, urlString: att.url, isVideo: isVideo)
                        } label: {
                            ZStack {
                                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                                    BrandColor.bgSecondary
                                }
                                if isVideo {
                                    Image(systemName: "play.circle.fill")
                                        .font(.system(size: 26))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .shadow(radius: 3)
                                }
                            }
                            .frame(maxWidth: 220, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let body = message.body, !body.isEmpty {
                    Text(body)
                        .font(BrandFont.body(15))
                        .foregroundStyle(isMine ? BrandColor.onAccent : BrandColor.textPrimary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(isMine ? BrandColor.accent : BrandColor.bgSurface)
                        .opacity(message.status == .sending ? 0.6 : 1)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(isMine ? nil : RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(BrandColor.textMuted.opacity(0.12), lineWidth: 1))
                }
                footer
            }
            if !isMine { Spacer(minLength: 40) }
        }
        .mediaFullscreenCover($viewingMedia)
    }

    @ViewBuilder
    private var footer: some View {
        switch message.status {
        case .sending:
            Text("Sending…").font(BrandFont.mono(9)).foregroundStyle(BrandColor.textMuted)
        case .failed:
            Button(action: onRetry) {
                Text("Failed · Retry")
                    .font(BrandFont.mono(9)).foregroundStyle(BrandColor.ember)
            }
            .buttonStyle(.plain)
        case .sent:
            HStack(spacing: 5) {
                Text(timeLabel).font(BrandFont.mono(9)).foregroundStyle(BrandColor.textMuted)
                if isMine && isRead {
                    Text("Read").font(BrandFont.mono(9)).foregroundStyle(BrandColor.accent)
                }
            }
        }
    }

    private var timeLabel: String {
        guard let date = Wire.date(message.createdAt) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}
