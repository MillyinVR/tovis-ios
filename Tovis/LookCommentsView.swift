// Comments for a look — the native take on the web CommentsDrawer (TikTok/IG
// parity): top-level comments newest-first, 1-level replies loaded on demand,
// like a comment, reply, and delete-your-own. The wire models are immutable
// outside TovisKit, so per-comment viewer state (liked/likeCount/replyCount) is
// layered in id-keyed dictionaries and reconciled with the server.
import SwiftUI
import TovisKit

struct LookCommentsView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let look: LooksFeedItem
    /// Reports the net change in this look's comment count back to the feed.
    var onCountChange: (Int) -> Void = { _ in }

    @State private var comments: [LooksComment] = []
    @State private var loading = true
    @State private var loadError: String?

    @State private var draft = ""
    @State private var sending = false
    @State private var replyingTo: ReplyTarget?

    @State private var expanded: Set<String> = []
    @State private var replies: [String: [LooksComment]] = [:]
    @State private var loadingReplies: Set<String> = []

    // Optimistic overrides, keyed by comment id.
    @State private var likeOverrides: [String: Bool] = [:]
    @State private var likeCounts: [String: Int] = [:]
    @State private var replyCountOverrides: [String: Int] = [:]
    @State private var removed: Set<String> = []

    @FocusState private var composerFocused: Bool

    private struct ReplyTarget: Equatable { let commentId: String; let name: String }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                content
                composer
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(BrandColor.accent)
                }
            }
        }
        .tint(BrandColor.accent)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            Spacer(); ProgressView().tint(BrandColor.accent); Spacer()
        } else if let loadError {
            Spacer()
            VStack(spacing: 12) {
                Text(loadError).font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
                Button("Try again") { Task { await load() } }
                    .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.accent)
            }
            Spacer()
        } else if visibleTopLevel.isEmpty {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 28)).foregroundStyle(BrandColor.textMuted)
                Text("No comments yet").font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("Be the first to comment.").font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
            }
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(visibleTopLevel) { comment in
                        commentThread(comment)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
    }

    @ViewBuilder
    private func commentThread(_ comment: LooksComment) -> some View {
        CommentRow(
            comment: comment,
            liked: liked(comment),
            likeCount: likeCount(comment),
            isReply: false,
            onLike: { Task { await toggleLike(comment) } },
            onReply: { startReply(to: comment) },
            onDelete: comment.viewerCanDelete ? { Task { await delete(comment) } } : nil
        )

        let count = replyCount(comment)
        if count > 0 {
            let shown = expanded.contains(comment.id)
            Button {
                Task { await toggleReplies(comment) }
            } label: {
                HStack(spacing: 6) {
                    Rectangle().fill(BrandColor.textMuted.opacity(0.4)).frame(width: 22, height: 1)
                    if loadingReplies.contains(comment.id) {
                        ProgressView().controlSize(.mini).tint(BrandColor.accent)
                    }
                    Text(shown ? "Hide replies" : "View \(count) \(count == 1 ? "reply" : "replies")")
                        .font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textMuted)
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 44)

            if shown {
                ForEach(visibleReplies(comment.id)) { reply in
                    CommentRow(
                        comment: reply,
                        liked: liked(reply),
                        likeCount: likeCount(reply),
                        isReply: true,
                        onLike: { Task { await toggleLike(reply) } },
                        onReply: { startReply(to: comment) },   // 1-level: re-root to parent
                        onDelete: reply.viewerCanDelete ? { Task { await delete(reply) } } : nil
                    )
                    .padding(.leading, 44)
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            if let replyingTo {
                HStack(spacing: 6) {
                    Text("Replying to \(replyingTo.name)")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                    Spacer()
                    Button { self.replyingTo = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(BrandColor.textMuted)
                    }
                }
                .padding(.horizontal, 18).padding(.top, 8)
            }
            HStack(spacing: 10) {
                TextField("Add a comment…", text: $draft, axis: .vertical)
                    .font(BrandFont.body(15))
                    .foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(BrandColor.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))

                Button { Task { await send() } } label: {
                    if sending {
                        ProgressView().tint(BrandColor.accent)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(canSend ? BrandColor.accent : BrandColor.textMuted.opacity(0.4))
                    }
                }
                .disabled(!canSend || sending)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(BrandColor.bgPrimary)
        .overlay(Rectangle().fill(BrandColor.textMuted.opacity(0.12)).frame(height: 1), alignment: .top)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - Derived

    private var visibleTopLevel: [LooksComment] {
        comments.filter { !$0.isReply && !removed.contains($0.id) }
    }
    private func visibleReplies(_ parentId: String) -> [LooksComment] {
        (replies[parentId] ?? []).filter { !removed.contains($0.id) }
    }
    private func liked(_ c: LooksComment) -> Bool { likeOverrides[c.id] ?? c.viewerLiked }
    private func likeCount(_ c: LooksComment) -> Int { likeCounts[c.id] ?? c.likeCount }
    private func replyCount(_ c: LooksComment) -> Int { replyCountOverrides[c.id] ?? c.replyCount }

    // MARK: - Actions

    private func load() async {
        loading = true; loadError = nil
        defer { loading = false }
        do {
            comments = try await session.client.looks.comments(lookId: look.id)
        } catch let error as APIError {
            loadError = error.userMessage
        } catch {
            loadError = "Couldn’t load comments."
        }
    }

    private func startReply(to comment: LooksComment) {
        replyingTo = ReplyTarget(commentId: comment.id, name: comment.user.displayName)
        composerFocused = true
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        let parentId = replyingTo?.commentId
        do {
            let created = try await session.client.looks.addComment(
                lookId: look.id, body: text, parentCommentId: parentId
            )
            draft = ""
            replyingTo = nil
            composerFocused = false
            if let parentId {
                replies[parentId, default: []].append(created)
                expanded.insert(parentId)
                replyCountOverrides[parentId] = replyCount(forId: parentId) + 1
            } else {
                comments.insert(created, at: 0)
            }
            onCountChange(1)
        } catch let error as APIError {
            loadError = error.userMessage
        } catch {
            loadError = "Couldn’t post your comment."
        }
    }

    private func replyCount(forId id: String) -> Int {
        if let o = replyCountOverrides[id] { return o }
        return comments.first { $0.id == id }?.replyCount ?? 0
    }

    private func toggleReplies(_ comment: LooksComment) async {
        if expanded.contains(comment.id) { expanded.remove(comment.id); return }
        if replies[comment.id] == nil {
            loadingReplies.insert(comment.id)
            defer { loadingReplies.remove(comment.id) }
            do {
                replies[comment.id] = try await session.client.looks.replies(
                    lookId: look.id, commentId: comment.id
                )
            } catch {
                return
            }
        }
        expanded.insert(comment.id)
    }

    private func toggleLike(_ comment: LooksComment) async {
        let next = !liked(comment)
        let base = likeCount(comment)
        likeOverrides[comment.id] = next
        likeCounts[comment.id] = max(0, base + (next ? 1 : -1))
        do {
            let res = try await session.client.looks.setCommentLiked(
                lookId: look.id, commentId: comment.id, liked: next
            )
            likeOverrides[comment.id] = res.liked
            likeCounts[comment.id] = res.likeCount
        } catch {
            likeOverrides[comment.id] = !next
            likeCounts[comment.id] = base
        }
    }

    private func delete(_ comment: LooksComment) async {
        let wasRemoved = removed.contains(comment.id)
        removed.insert(comment.id)
        do {
            try await session.client.looks.deleteComment(lookId: look.id, commentId: comment.id)
            // Top-level delete soft-removes the whole thread on the server.
            let removedReplies = comment.isReply ? 0 : (replies[comment.id]?.count ?? replyCount(comment))
            onCountChange(-(1 + removedReplies))
        } catch {
            if !wasRemoved { removed.remove(comment.id) }   // revert
        }
    }
}

// MARK: - One comment row (top-level or reply)

private struct CommentRow: View {
    let comment: LooksComment
    let liked: Bool
    let likeCount: Int
    let isReply: Bool
    let onLike: () -> Void
    let onReply: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BrandAvatar(name: comment.user.displayName, avatarUrl: comment.user.avatarUrl, size: isReply ? 28 : 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.user.displayName)
                        .font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    Text(relativeTime(comment.createdAt))
                        .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                }
                Text(comment.body)
                    .font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 16) {
                    Button(action: onReply) {
                        Text("Reply").font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textMuted)
                    }
                    .buttonStyle(.plain)
                    if let onDelete {
                        Button(action: onDelete) {
                            Text("Delete").font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.ember)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 6)

            Button(action: onLike) {
                VStack(spacing: 3) {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 15))
                        .foregroundStyle(liked ? BrandColor.ember : BrandColor.textMuted)
                    if likeCount > 0 {
                        Text("\(likeCount)").font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func relativeTime(_ iso: String) -> String {
        guard let date = Wire.date(iso) else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
