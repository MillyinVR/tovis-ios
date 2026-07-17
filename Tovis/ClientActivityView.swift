import SwiftUI
import TovisKit

/// The client "Activity" feed — a 1:1 port of web's `/client/activity`
/// (`ClientActivityFrame.tsx`): the creator-engagement surface, distinct from the
/// transactional notification centre `NotificationsView` renders.
///
/// The row copy (`who`/`action`/`highlight`) is composed server-side and rendered
/// verbatim, so the two platforms cannot drift; only the relative timestamp is
/// formatted natively (see `ActivityTimeAgo`). Row order, wording, the "Mark all
/// read" affordance and the empty state all mirror web.
struct ClientActivityView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        /// Rows live in `rows` (they get patched by mark-read), so the loaded case
        /// carries no payload — a second copy here could only go stale.
        case loaded
        case failed(String)
    }

    @State private var phase: Phase = .loading
    /// Rows held separately from `phase` so a follow-back / mark-read can patch
    /// them without a refetch.
    @State private var rows: [ClientActivityItem] = []
    @State private var unread = 0
    @State private var markReadEventKeys: [String] = []
    @State private var marking = false
    /// Mark-all-read is idempotent server-side, but there is no reason to re-send
    /// it once it has succeeded for this presentation.
    @State private var marked = false

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    failedState(message)
                case .loaded:
                    content
                }
            }
            .background(BrandColor.bgPrimary)
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if hasUnread {
                        Button("Mark all read") { Task { await markAllRead() } }
                            .font(BrandFont.body(13, .semibold))
                            .tint(BrandColor.accent)
                            .disabled(marking)
                    }
                }
            }
        }
        .task { await load() }
    }

    private var hasUnread: Bool { unread > 0 }

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(rows) { item in
                        ActivityRow(item: item)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 28)
            }
            .refreshable { await load() }
        }
    }

    /// Web's empty card, verbatim.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No activity yet")
                .font(BrandFont.body(15, .bold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("When someone follows you or engages with your looks, it’ll show up here.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
        .background(BrandColor.bgSecondary, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(BrandColor.textPrimary.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.top, 24)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// A failed LOAD is its own state — never rendered as "you have no activity".
    /// Telling someone nobody engaged with their work when we simply couldn't read
    /// the feed is a lie the empty state would tell for us.
    private func failedState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text("Couldn’t load your activity")
                .font(BrandFont.body(15, .bold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(message)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }
                .font(BrandFont.body(13, .semibold))
                .tint(BrandColor.accent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func load() async {
        do {
            let feed = try await session.client.activity.feed()
            rows = feed.items
            unread = max(0, feed.unreadCount)
            markReadEventKeys = feed.markReadEventKeys
            // Re-arm: this screen can refetch (web's cannot), so a fresh batch of
            // unread rows must be markable again. Leaving it latched would show a
            // live "Mark all read" that does nothing.
            marked = false
            phase = .loaded
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your activity.")
        }
    }

    private func markAllRead() async {
        guard !marking, !marked, hasUnread else { return }
        marking = true
        let previousRows = rows
        let previousUnread = unread
        // Optimistic: clear the badge + the unread dots immediately (web does the
        // same, and rolls back identically).
        unread = 0
        rows = rows.map { $0.markingRead() }
        do {
            // Hand back the server's OWN allowlist rather than a hard-coded list —
            // which events count as "activity" is the backend's to decide.
            try await session.client.notifications.markRead(eventKeys: markReadEventKeys)
            marked = true
            // The Me-header bell reads activityUnreadCount off /api/v1/me, so it
            // must re-read to drop its badge.
            session.signalRefresh()
        } catch {
            rows = previousRows
            unread = previousUnread
        }
        marking = false
    }
}

// MARK: - Row

private struct ActivityRow: View {
    let item: ClientActivityItem

    var body: some View {
        let style = ActivityRowStyle.forKind(item.iconKind)
        BrandSurface(tint: item.unread ? BrandColor.bgSurface : BrandColor.bgSecondary) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(style.tint.opacity(0.14))
                        .frame(width: 42, height: 42)
                    Image(systemName: style.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(style.tint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    // `who` is bold, `action` regular, `highlight` accented —
                    // web's ActivityRow composition. All three are server-composed
                    // copy, so every Text is `verbatim`: a plain Text("\(…)") is a
                    // LocalizedStringKey and would put this through a localization
                    // lookup rather than rendering exactly what the server sent.
                    (
                        Text(verbatim: item.who).font(BrandFont.body(13.5, .bold))
                            .foregroundColor(BrandColor.textPrimary)
                            + Text(verbatim: " \(item.action)").font(BrandFont.body(13.5))
                            .foregroundColor(BrandColor.textPrimary)
                            + Text(verbatim: item.highlight.map { " \($0)" } ?? "")
                            .font(BrandFont.body(13.5, .semibold))
                            .foregroundColor(BrandColor.accent)
                    )
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        if item.unread {
                            Circle().fill(BrandColor.accent).frame(width: 6, height: 6)
                        }
                        Text(verbatim: ActivityTimeAgo.label(for: item.timestamp).uppercased())
                            .font(BrandFont.mono(10))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }

                Spacer(minLength: 4)

                trailing
            }
        }
    }

    /// Follow-back wins over "View" — web's ActivityRow branches the same way.
    ///
    /// `offersFollowBack` governs only this INITIAL choice; once the button is on
    /// screen it owns its own state and stays a toggle, exactly as web's
    /// `FollowBackButton` does. Retiring it to "View" the moment a follow lands
    /// would make a mis-tap unrecoverable from this surface — and web doesn't.
    /// A reopened feed re-reads `alreadyFollowing` from the server and then
    /// correctly shows "View".
    @ViewBuilder
    private var trailing: some View {
        if let followBack = item.followBack, item.offersFollowBack {
            ActivityFollowBackButton(handle: followBack.handle)
        } else if let destination = item.destination {
            NavigationLink {
                switch destination {
                case .look(let id): LookDetailView(lookId: id)
                case .publicClient(let handle): PublicClientViewerView(handle: handle)
                }
            } label: {
                Text("View")
                    .font(BrandFont.body(11.5, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
                    .padding(.vertical, 6).padding(.horizontal, 12)
                    .overlay(
                        Capsule().stroke(BrandColor.textPrimary.opacity(0.15), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }
}

/// The compact inline follow-back pill. Deliberately not the 120pt-wide button
/// `PublicClientProfileContent` uses — that one also owns a follower count this
/// row has no room (or data) for; only the optimistic toggle is common, and it is
/// eight lines. See the handoff note about consolidating iOS's follow buttons.
private struct ActivityFollowBackButton: View {
    let handle: String

    @Environment(SessionModel.self) private var session
    @State private var following = false
    @State private var working = false

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            Text(following ? "Following" : "Follow")
                .font(BrandFont.body(11.5, .bold))
                .foregroundStyle(following ? BrandColor.textPrimary : BrandColor.onAccent)
                .padding(.vertical, 7).padding(.horizontal, 14)
                .background(
                    following ? AnyShapeStyle(BrandColor.bgPrimary) : AnyShapeStyle(BrandColor.accent),
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(
                        BrandColor.textPrimary.opacity(following ? 0.15 : 0), lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(working)
        .opacity(working ? 0.7 : 1)
        .accessibilityLabel(following ? "Following \(handle)" : "Follow \(handle)")
    }

    private func toggle() async {
        guard !working else { return }
        let next = !following
        working = true
        following = next  // optimistic
        do {
            // The backend route is a TOGGLE, so reconcile with what it reports
            // rather than assuming our flip won.
            let state = try await session.client.publicClient.toggleFollow(handle: handle)
            following = state.following
        } catch {
            following = !next  // roll back
        }
        working = false
    }
}

/// SF Symbol + tint for a row, derived from the server's `iconKind`. Mirrors the
/// lucide glyphs + tone colours web's `ICONS` map uses.
private struct ActivityRowStyle {
    let symbol: String
    let tint: Color

    static func forKind(_ kind: ActivityIconKind) -> ActivityRowStyle {
        switch kind {
        case .follow:
            return .init(symbol: "person.badge.plus", tint: BrandColor.iris)
        case .comment:
            return .init(symbol: "bubble.left", tint: BrandColor.accent)
        case .like:
            return .init(symbol: "heart.fill", tint: BrandColor.ember)
        case .save:
            return .init(symbol: "bookmark.fill", tint: BrandColor.gold)
        case .newLook:
            return .init(symbol: "camera", tint: BrandColor.accent)
        case .remix:
            return .init(symbol: "arrow.2.squarepath", tint: BrandColor.accent)
        case .featured:
            return .init(symbol: "sparkles", tint: BrandColor.iris)
        case .milestone:
            return .init(symbol: "trophy.fill", tint: BrandColor.gold)
        // A kind this build predates still renders a whole, readable row.
        case .unknown:
            return .init(symbol: "bell", tint: BrandColor.accent)
        }
    }
}
