// A single conversation — GET /api/v1/messages/threads/{id} + POST to send, and
// POST .../read to clear unread. Native rebuild of the web thread view: chat
// bubbles (mine right/accent, theirs left/surface) with a pinned composer, day
// separators, read receipts, and optimistic send with retry.
import PhotosUI
import SwiftUI
import TovisKit
import UIKit

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
    /// Local image for an optimistic attachment send, shown until the server
    /// message (with a signed URL) swaps in. nil for server rows.
    let localImage: UIImage?
    /// Uploaded media-private path(s) for an optimistic attachment send, so a
    /// retry re-POSTs without re-uploading the bytes.
    var retryAttachmentPaths: [String]
    var status: Status

    init(server: Message) {
        id = server.id
        clientId = nil
        body = server.body
        createdAt = server.createdAt
        senderUserId = server.senderUserId
        attachments = server.attachments
        localImage = nil
        retryAttachmentPaths = []
        status = .sent
    }

    init(created: CreatedMessage) {
        id = created.id
        clientId = nil
        body = created.body
        createdAt = created.createdAt
        senderUserId = created.senderUserId
        attachments = created.attachments ?? []
        localImage = nil
        retryAttachmentPaths = []
        status = .sent
    }

    init(
        optimistic clientId: String,
        body: String,
        senderUserId: String,
        createdAt: String,
        localImage: UIImage? = nil
    ) {
        id = clientId
        self.clientId = clientId
        self.body = body
        self.createdAt = createdAt
        self.senderUserId = senderUserId
        attachments = []
        self.localImage = localImage
        retryAttachmentPaths = []
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

    // A single image staged in the composer, previewed until it's uploaded + sent.
    @State private var pickerItem: PhotosPickerItem?
    @State private var pendingImage: UIImage?
    @State private var pendingImageData: Data?

    // "Load earlier" cursor paging. `olderCursor` is the oldest loaded message's
    // id; the 15s poll never touches it (it only refetches the newest page).
    @State private var olderCursor: String?
    @State private var hasMoreOlder = false
    @State private var loadingOlder = false

    // Context navigation (see `contextBar`). The client's "View booking" has to
    // resolve the booking before it can push, so it carries its own in-flight and
    // error state; every other context link is a plain push.
    @State private var contextBookingNav: ClientBookingNav?
    @State private var resolvingBooking = false
    @State private var contextError: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if hasMoreOlder {
                        Button { Task { await loadOlder(proxy) } } label: {
                            if loadingOlder {
                                ProgressView().tint(BrandColor.textMuted)
                            } else {
                                Text("Load earlier messages")
                                    .font(BrandFont.mono(10)).tracking(0.7)
                                    .foregroundStyle(BrandColor.textSecondary)
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .overlay(Capsule().stroke(BrandColor.textMuted.opacity(0.2), lineWidth: 1))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(loadingOlder)
                        .padding(.bottom, 2)
                    }
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
            // Scroll to bottom only when the NEWEST message changes (send / new
            // incoming) — not when "load earlier" prepends older ones.
            .onChange(of: messages.last?.id) { scrollToBottom(proxy) }
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
        .safeAreaInset(edge: .top) { contextBar }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationDestination(item: $contextBookingNav) { nav in
            BookingDetailView(booking: nav.booking)
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Context navigation

    /// Jumps into the thread's own context, mirroring the web thread header's
    /// "View booking" / "View profile" links plus, for the thread's pro, "View
    /// client chart" (app/messages/thread/[id]/page.tsx). Which links show is the
    /// model's call (`contextDestination` / `showsClientChartLink`), so the two
    /// clients can't drift.
    ///
    /// Web stacks these under the page title; the native title lives in the nav
    /// bar, so they pin just below it rather than riding the scroll content — a
    /// thread opens scrolled to the newest message, where a header inside the
    /// scroll would start off-screen. Renders nothing (and takes no space) for a
    /// context with no destination.
    @ViewBuilder
    private var contextBar: some View {
        if thread.contextDestination != nil || thread.showsClientChartLink {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 18) {
                    contextDestinationLink
                    if thread.showsClientChartLink {
                        NavigationLink {
                            ProClientChartView(
                                clientId: thread.client.id,
                                fullName: thread.client.displayName
                            )
                        } label: {
                            contextLinkLabel("View client chart")
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                if let contextError {
                    Text(contextError)
                        .font(BrandFont.body(11.5))
                        .foregroundStyle(BrandColor.ember)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(BrandColor.bgPrimary)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(BrandColor.textMuted.opacity(0.15))
                    .frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private var contextDestinationLink: some View {
        if let destination = thread.contextDestination {
            switch destination {
            case let .booking(id):
                // Web has one dual-role receipt at /booking/{id}; native splits it,
                // and only the pro's side fetches from a bare id.
                if thread.isViewerPro {
                    NavigationLink {
                        ProBookingDetailView(bookingId: id)
                    } label: {
                        contextLinkLabel("View booking")
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { Task { await openClientBooking(id: id) } } label: {
                        contextLinkLabel("View booking", working: resolvingBooking)
                    }
                    .buttonStyle(.plain)
                    .disabled(resolvingBooking)
                }
            case let .proProfile(id):
                NavigationLink {
                    ProProfileView(
                        professionalId: id,
                        fallbackName: thread.professional.displayName
                    )
                } label: {
                    contextLinkLabel("View profile")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func contextLinkLabel(_ title: String, working: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title)
            if working {
                ProgressView().controlSize(.mini).tint(BrandColor.accent)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .font(BrandFont.body(12.5, .semibold))
        .foregroundStyle(BrandColor.accent)
    }

    /// Resolve the thread's booking, then push its detail. `BookingDetailView`
    /// takes the whole `ClientBooking` because there's no single-booking client
    /// GET, so this goes through the bucketed list (`BookingsService.booking(id:)`)
    /// — best-effort: a booking that isn't there, or a failed load, says so inline
    /// instead of pushing an empty screen.
    private func openClientBooking(id: String) async {
        guard !resolvingBooking else { return }
        resolvingBooking = true
        contextError = nil
        defer { resolvingBooking = false }

        do {
            if let booking = try await session.client.bookings.booking(id: id) {
                contextBookingNav = ClientBookingNav(booking: booking)
            } else {
                contextError = "Couldn’t find that booking."
            }
        } catch {
            contextError = "Couldn’t open that booking."
        }
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let errorMessage {
                Text(errorMessage).font(BrandFont.body(11.5)).foregroundStyle(BrandColor.ember)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let pendingImage {
                HStack {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: pendingImage)
                            .resizable().scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Button { clearPendingImage() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(BrandColor.textSecondary)
                                .background(Circle().fill(BrandColor.bgPrimary))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                    }
                    Spacer()
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(BrandColor.textSecondary)
                        .frame(width: 38, height: 38)
                        .background(BrandColor.bgSurface)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))
                }
                .disabled(sending)

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
        .onChange(of: pickerItem) { Task { await loadPickedImage() } }
    }

    private var canSend: Bool {
        guard !sending else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || pendingImageData != nil
    }

    /// Load the picked photo, normalizing to JPEG so it renders everywhere
    /// (including the web thread) and stays a reasonable size.
    private func loadPickedImage() async {
        guard let item = pickerItem else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else {
                errorMessage = "Couldn’t load that image."
                pickerItem = nil
                return
            }
            pendingImage = uiImage
            pendingImageData = uiImage.jpegData(compressionQuality: 0.85) ?? data
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t load that image."
        }
        pickerItem = nil
    }

    private func clearPendingImage() {
        pendingImage = nil
        pendingImageData = nil
        pickerItem = nil
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
            let wasFirstLoad = !loaded
            let page = try await session.client.messages.messages(threadId: thread.id)
            applyServer(page)
            // Seed the "load earlier" cursor from the first page only — later
            // polls refetch the newest page, whose cursor would walk forward and
            // clobber the oldest-loaded boundary we've paged back to.
            if wasFirstLoad {
                olderCursor = page.nextCursor
                hasMoreOlder = page.hasMore
            }
            loaded = true
            try? await session.client.messages.markRead(threadId: thread.id)
            if let proxy { scrollToBottom(proxy) }
        } catch let error as APIError {
            if !loaded { errorMessage = error.userMessage }
        } catch {
            if !loaded { errorMessage = "Couldn’t load this conversation." }
        }
    }

    /// Fetch the messages older than the current cursor and prepend them,
    /// keeping the previously-topmost message in view so the list doesn't jump.
    private func loadOlder(_ proxy: ScrollViewProxy) async {
        guard hasMoreOlder, !loadingOlder, let cursor = olderCursor else { return }
        loadingOlder = true
        defer { loadingOlder = false }

        let anchorId = messages.first?.id
        do {
            let page = try await session.client.messages.messages(threadId: thread.id, cursor: cursor)
            let existingIds = Set(messages.map(\.id))
            let older = page.messages
                .map(ThreadMessage.init(server:))
                .filter { !existingIds.contains($0.id) }
            if !older.isEmpty {
                messages = older + messages
                if let anchorId { proxy.scrollTo(anchorId, anchor: .top) }
            }
            olderCursor = page.nextCursor
            hasMoreOlder = page.hasMore
        } catch {
            // Transient — leave the button so the user can retry.
        }
    }

    /// Merge a fresh server page over local state, preserving any older pages the
    /// user loaded via "load earlier" AND any optimistic (sending/failed) rows the
    /// server doesn't know about yet.
    private func applyServer(_ page: MessageThreadPage) {
        counterpartyLastReadAt = page.counterpartyLastReadAt
        let pending = messages.filter { $0.status != .sent }

        var byId: [String: ThreadMessage] = [:]
        for message in messages where message.status == .sent { byId[message.id] = message }
        for message in page.messages { byId[message.id] = ThreadMessage(server: message) }

        let merged = byId.values.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
        }
        messages = merged + pending
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageData = pendingImageData
        let image = pendingImage
        guard (!text.isEmpty || imageData != nil), !sending, let mine = myUserId else { return }

        let clientId = UUID().uuidString
        messages.append(ThreadMessage(
            optimistic: clientId, body: text, senderUserId: mine,
            createdAt: Wire.nowISO(), localImage: image
        ))
        draft = ""
        clearPendingImage()
        errorMessage = nil
        sending = true
        defer { sending = false }

        var attachmentPaths: [String] = []
        if let imageData {
            do {
                let path = try await session.client.messages.uploadAttachment(
                    threadId: thread.id, imageData: imageData
                )
                attachmentPaths = [path]
                setRetryPaths(clientId: clientId, paths: attachmentPaths)
            } catch {
                // Upload failed before the message was created — drop the
                // optimistic row and restore the composer for a full retry.
                messages.removeAll { $0.clientId == clientId }
                draft = text
                pendingImage = image
                pendingImageData = imageData
                errorMessage = "Couldn’t upload that image."
                return
            }
        }

        await post(text, attachmentPaths: attachmentPaths, clientId: clientId)
    }

    private func retry(_ message: ThreadMessage) async {
        guard let clientId = message.clientId else { return }
        let hasBody = !(message.body ?? "").isEmpty
        guard hasBody || !message.retryAttachmentPaths.isEmpty else { return }
        setStatus(clientId: clientId, to: .sending)
        errorMessage = nil
        await post(
            message.body ?? "",
            attachmentPaths: message.retryAttachmentPaths,
            clientId: clientId
        )
    }

    /// Send a message (text and/or already-uploaded attachment paths); swap the
    /// optimistic row for the server message on success, mark it failed on error.
    private func post(_ text: String, attachmentPaths: [String] = [], clientId: String) async {
        do {
            let created = try await session.client.messages.send(
                threadId: thread.id, body: text, attachmentPaths: attachmentPaths
            )
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

    private func setRetryPaths(clientId: String, paths: [String]) {
        messages = messages.map {
            guard $0.clientId == clientId else { return $0 }
            var next = $0
            next.retryAttachmentPaths = paths
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
                if let localImage = message.localImage {
                    Image(uiImage: localImage)
                        .resizable().scaledToFill()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .opacity(message.status == .sending ? 0.6 : 1)
                }
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
