// Pro notification center — the native port of web `/pro/notifications`. A feed of
// per-event rows (icon/tint, unread dot), tap-to-mark-read, Mark all read, cursor
// pagination. Booking notifications push the pro booking detail. Reached from the
// bell on the Calendar tab. Distinct surface from the client center.
import SwiftUI
import TovisKit

struct ProNotificationsView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var items: [ProNotification] = []
    @State private var nextCursor: String?
    @State private var loading = true
    @State private var loadingMore = false
    @State private var error: String?
    /// Ids marked read this session (optimistic; the model is immutable).
    @State private var locallyRead: Set<String> = []

    private func isUnread(_ item: ProNotification) -> Bool {
        item.isUnread && !locallyRead.contains(item.id)
    }
    private var hasUnread: Bool { items.contains { isUnread($0) } }

    var body: some View {
        NavigationStack {
            Group {
                if loading && items.isEmpty {
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .frame(maxHeight: .infinity)
                } else if items.isEmpty {
                    emptyState
                } else {
                    feed
                }
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.tint(BrandColor.accent)
                }
                ToolbarItem(placement: .primaryAction) {
                    if hasUnread {
                        Button("Mark all read") { Task { await markAll() } }
                            .tint(BrandColor.accent)
                            .font(BrandFont.body(14))
                    }
                }
            }
            .task { if loading { await load() } }
            .tint(BrandColor.accent)
        }
    }

    private var feed: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    row(item)
                    Divider().overlay(BrandColor.textMuted.opacity(0.1)).padding(.leading, 64)
                }
                if nextCursor != nil {
                    ProgressView()
                        .tint(BrandColor.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .task { await loadMore() }
                }
            }
            .padding(.top, 4)
        }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func row(_ item: ProNotification) -> some View {
        let content = rowBody(item)
        if let bookingId = item.bookingId {
            NavigationLink {
                ProBookingDetailView(bookingId: bookingId)
            } label: { content }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { Task { await markRead(item) } })
        } else {
            Button { Task { await markRead(item) } } label: { content }
                .buttonStyle(.plain)
        }
    }

    private func rowBody(_ item: ProNotification) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(tint(item).opacity(0.15)).frame(width: 38, height: 38)
                Image(systemName: icon(item))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint(item))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                if let body = item.body, !body.isEmpty {
                    Text(body)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                        .lineLimit(3)
                }
                Text(Wire.relativeAgo(item.createdAt))
                    .font(BrandFont.mono(10))
                    .foregroundStyle(BrandColor.textMuted)
            }
            Spacer()
            if isUnread(item) {
                Circle().fill(BrandColor.accent).frame(width: 8, height: 8).padding(.top, 6)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .background(isUnread(item) ? BrandColor.accent.opacity(0.04) : Color.clear)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 30))
                .foregroundStyle(BrandColor.textMuted)
            Text("You're all caught up")
                .font(BrandFont.display(18, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            if let error {
                Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Icons

    private func icon(_ item: ProNotification) -> String {
        let key = item.eventKey.uppercased()
        if key.contains("BOOKING") || key.contains("REQUEST") { return "calendar" }
        if key.contains("REVIEW") { return "star.fill" }
        if key.contains("PAYMENT") || key.contains("PAYOUT") { return "creditcard.fill" }
        if key.contains("MESSAGE") { return "bubble.left.fill" }
        if key.contains("WAITLIST") { return "person.2.fill" }
        if key.contains("AFTERCARE") { return "heart.text.square.fill" }
        return "bell.fill"
    }

    private func tint(_ item: ProNotification) -> Color {
        let key = item.eventKey.uppercased()
        if key.contains("PAYMENT") || key.contains("PAYOUT") { return BrandColor.emerald }
        if key.contains("REVIEW") { return BrandColor.gold }
        if key.contains("CANCEL") || key.contains("DECLINE") { return BrandColor.ember }
        return BrandColor.accent
    }

    // MARK: - Actions

    private func load() async {
        loading = items.isEmpty
        error = nil
        do {
            let page = try await session.client.proNotifications.feed()
            items = page.items
            nextCursor = page.nextCursor
        } catch let e as APIError {
            error = e.userMessage
        } catch {
            self.error = "Couldn’t load notifications."
        }
        loading = false
    }

    private func loadMore() async {
        guard !loadingMore, let cursor = nextCursor else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let page = try? await session.client.proNotifications.feed(cursor: cursor) {
            items.append(contentsOf: page.items)
            nextCursor = page.nextCursor
        } else {
            nextCursor = nil
        }
    }

    private func markRead(_ item: ProNotification) async {
        guard isUnread(item) else { return }
        locallyRead.insert(item.id)   // optimistic
        try? await session.client.proNotifications.markRead(id: item.id)
        session.signalRefresh()
    }

    private func markAll() async {
        locallyRead.formUnion(items.map(\.id))   // optimistic
        _ = try? await session.client.proNotifications.markAllRead()
        session.signalRefresh()
    }
}
