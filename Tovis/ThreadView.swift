// A single conversation — GET /api/v1/messages/threads/{id} + POST to send, and
// POST .../read to clear unread. Native rebuild of the web thread view: chat
// bubbles (mine right/accent, theirs left/surface) with a pinned composer.
import SwiftUI
import TovisKit

struct ThreadView: View {
    @Environment(SessionModel.self) private var session
    let thread: MessageThread

    @State private var messages: [Message] = []
    @State private var myUserId: String?
    @State private var draft: String = ""
    @State private var loaded = false
    @State private var sending = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { message in
                        MessageBubble(message: message, isMine: message.senderUserId == myUserId)
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
        .navigationTitle(thread.professional.displayName)
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
            messages = try await session.client.messages.messages(threadId: thread.id)
            loaded = true
            try? await session.client.messages.markRead(threadId: thread.id)
            if let proxy { scrollToBottom(proxy) }
        } catch let error as APIError {
            if !loaded { errorMessage = error.userMessage }
        } catch {
            if !loaded { errorMessage = "Couldn’t load this conversation." }
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        errorMessage = nil
        do {
            _ = try await session.client.messages.send(threadId: thread.id, body: text)
            draft = ""
            messages = try await session.client.messages.messages(threadId: thread.id)
        } catch let error as APIError {
            errorMessage = error.userMessage
        } catch {
            errorMessage = "Couldn’t send. Try again."
        }
        sending = false
    }
}

private struct MessageBubble: View {
    let message: Message
    let isMine: Bool

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 40) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 6) {
                ForEach(message.attachments) { att in
                    if let url = URL(string: att.url) {
                        AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: {
                            BrandColor.bgSecondary
                        }
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                if let body = message.body, !body.isEmpty {
                    Text(body)
                        .font(BrandFont.body(15))
                        .foregroundStyle(isMine ? BrandColor.onAccent : BrandColor.textPrimary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(isMine ? BrandColor.accent : BrandColor.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(isMine ? nil : RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(BrandColor.textMuted.opacity(0.12), lineWidth: 1))
                }
                Text(timeLabel)
                    .font(BrandFont.mono(9)).foregroundStyle(BrandColor.textMuted)
            }
            if !isMine { Spacer(minLength: 40) }
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