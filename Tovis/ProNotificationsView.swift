// Pro notification center — native port of web `/pro/notifications` (1:1 parity).
// Filter chips (All · Unread · Requests · Updates · Cancelled · Reviews · Social),
// date-grouped sections (Today / Yesterday / "Thu, Jun 28") with per-day counts,
// per-event text badge + "Unread" badge + HH:MM timestamp, Mark all read, cursor
// pagination. Booking notifications push the pro booking detail.
import SwiftUI
import TovisKit

struct ProNotificationsView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Web filter categories, in the web's chip order.
    private enum Filter: String, CaseIterable, Identifiable {
        case all, unread, requests, updates, cancelled, reviews, social
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .unread: return "Unread"
            case .requests: return "Requests"
            case .updates: return "Updates"
            case .cancelled: return "Cancelled"
            case .reviews: return "Reviews"
            case .social: return "Social"
            }
        }
        /// The event-category this chip filters to (nil = no category filter).
        var category: String? {
            switch self {
            case .requests: return "REQUESTS"
            case .updates: return "UPDATES"
            case .cancelled: return "CANCELLED"
            case .reviews: return "REVIEWS"
            case .social: return "SOCIAL"
            default: return nil
            }
        }
    }

    @State private var items: [ProNotification] = []
    @State private var nextCursor: String?
    @State private var loading = true
    @State private var loadingMore = false
    @State private var error: String?
    @State private var filter: Filter = .all
    @State private var unreadCount = 0
    @State private var locallyRead: Set<String> = []

    private func isUnread(_ item: ProNotification) -> Bool {
        item.isUnread && !locallyRead.contains(item.id)
    }

    /// Items after the active category filter (Unread filter is server-side).
    private var visible: [ProNotification] {
        guard let category = filter.category else { return items }
        return items.filter { Self.category(of: $0.eventKey) == category }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusHeader
                chips
                Divider().overlay(BrandColor.textMuted.opacity(0.12))
                content
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
                    if unreadCount > 0 {
                        Button("Mark all read") { Task { await markAll() } }
                            .tint(BrandColor.accent).font(BrandFont.body(14))
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        NotificationPreferencesView(surface: .pro)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .tint(BrandColor.accent)
                }
            }
            .task { if loading { await load() } }
            .tint(BrandColor.accent)
        }
    }

    // MARK: - Header + chips

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(statusLine)
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var statusLine: String {
        if visible.isEmpty { return "No notifications yet" }
        var s = "Showing \(visible.count)"
        if let cat = filter.category {
            s += " • \(cat.capitalized)"
        }
        if filter == .unread { s += " • Unread only" }
        return s
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { f in
                    if f != .unread || unreadCount > 0 {
                        chip(f)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }

    private func chip(_ f: Filter) -> some View {
        let active = filter == f
        let label = f == .unread ? "Unread(\(unreadCount))" : f.label
        return Button {
            Task { await select(f) }
        } label: {
            Text(label)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textSecondary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(active ? BrandColor.accent : BrandColor.bgSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if loading && items.isEmpty {
            Spacer(); ProgressView().tint(BrandColor.accent).frame(maxWidth: .infinity); Spacer()
        } else if visible.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    ForEach(groupedByDay(visible), id: \.key) { group in
                        sectionHeader(group.key, count: group.items.count)
                        ForEach(group.items) { item in
                            row(item)
                            Divider().overlay(BrandColor.textMuted.opacity(0.1)).padding(.leading, 18)
                        }
                    }
                    if nextCursor != nil && filter.category == nil {
                        ProgressView().tint(BrandColor.accent)
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                            .task { await loadMore() }
                    }
                }
            }
            .refreshable { await load() }
        }
    }

    private func sectionHeader(_ key: String, count: Int) -> some View {
        HStack {
            Text(dayHeading(key))
                .font(BrandFont.mono(11)).tracking(0.5)
                .foregroundStyle(BrandColor.textMuted)
            Spacer()
            Text(count == 1 ? "1 item" : "\(count) items")
                .font(BrandFont.mono(10))
                .foregroundStyle(BrandColor.textMuted)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 6)
    }

    @ViewBuilder
    private func row(_ item: ProNotification) -> some View {
        let content = rowBody(item)
        if let bookingId = item.bookingId {
            NavigationLink { ProBookingDetailView(bookingId: bookingId) } label: { content }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { Task { await markRead(item) } })
        } else {
            Button { Task { await markRead(item) } } label: { content }.buttonStyle(.plain)
        }
    }

    private func rowBody(_ item: ProNotification) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.eventLabel(item.eventKey))
                    .font(BrandFont.mono(9)).tracking(0.5)
                    .foregroundStyle(BrandColor.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(BrandColor.bgSecondary)
                    .clipShape(Capsule())
                if isUnread(item) {
                    Text("Unread")
                        .font(BrandFont.mono(9)).tracking(0.5)
                        .foregroundStyle(BrandColor.accent)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(BrandColor.accent.opacity(0.12))
                        .clipShape(Capsule())
                }
                Spacer()
                Text(timeLabel(item.createdAt))
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
            }
            Text(item.title)
                .font(BrandFont.body(15, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            if let body = item.body, !body.isEmpty {
                Text(body)
                    .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(isUnread(item) ? BrandColor.accent.opacity(0.04) : Color.clear)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("You're caught up.")
                .font(BrandFont.display(20, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("Booking requests, schedule changes, cancellations, and reviews will appear here.")
                .font(BrandFont.body(14)).foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            if let error {
                Text(error).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Mapping (web parity)

    /// Event → category, matching the web's category groups.
    private static func category(of eventKey: String) -> String {
        let k = eventKey.uppercased()
        if k == "BOOKING_REQUEST_CREATED" { return "REQUESTS" }
        if k == "PAYMENT_CONFIRMATION_REQUIRED" { return "REQUESTS" }
        if k.contains("CANCELLED") { return "CANCELLED" }
        if k == "REVIEW_RECEIVED" { return "REVIEWS" }
        if k.hasPrefix("LOOK_") || k.contains("FOLLOWER") { return "SOCIAL" }
        return "UPDATES"
    }

    /// Event → human badge label, matching the web's eventKeyLabel.
    private static func eventLabel(_ eventKey: String) -> String {
        let k = eventKey.uppercased()
        if k == "BOOKING_REQUEST_CREATED" { return "Booking request" }
        if k == "PAYMENT_CONFIRMATION_REQUIRED" { return "Confirm payment" }
        if k.contains("CANCELLED") { return "Booking cancelled" }
        if k == "REVIEW_RECEIVED" { return "Review" }
        return "Booking update"
    }

    /// ISO instant → "2:45 PM".
    private func timeLabel(_ iso: String) -> String {
        guard let d = Wire.date(iso) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }

    // MARK: - Date grouping

    private struct DayGroup { let key: String; let items: [ProNotification] }

    private func groupedByDay(_ list: [ProNotification]) -> [DayGroup] {
        let cal = Calendar.current
        var order: [String] = []
        var byDay: [String: [ProNotification]] = [:]
        let keyFmt = DateFormatter()
        keyFmt.locale = Locale(identifier: "en_US_POSIX")
        keyFmt.dateFormat = "yyyy-MM-dd"
        for n in list {
            let day = Wire.date(n.createdAt) ?? Date()
            let key = keyFmt.string(from: cal.startOfDay(for: day))
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(n)
        }
        return order.map { DayGroup(key: $0, items: byDay[$0] ?? []) }
    }

    private func dayHeading(_ key: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: key) else { return key }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US")
        out.dateFormat = "EEE, MMM d"
        return out.string(from: date)
    }

    // MARK: - Actions

    private func select(_ f: Filter) async {
        filter = f
        // Unread is a server filter; categories are client-side over the loaded feed.
        if f == .unread || f == .all { await load() }
    }

    private func load() async {
        loading = items.isEmpty
        error = nil
        do {
            let page = try await session.client.proNotifications.feed(unreadOnly: filter == .unread)
            items = page.items
            nextCursor = page.nextCursor
            if let summary = try? await session.client.proNotifications.summary() {
                unreadCount = summary.count
            }
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
        if let page = try? await session.client.proNotifications.feed(
            unreadOnly: filter == .unread, cursor: cursor
        ) {
            items.append(contentsOf: page.items)
            nextCursor = page.nextCursor
        } else {
            nextCursor = nil
        }
    }

    private func markRead(_ item: ProNotification) async {
        guard isUnread(item) else { return }
        locallyRead.insert(item.id)
        unreadCount = max(0, unreadCount - 1)
        try? await session.client.proNotifications.markRead(id: item.id)
        session.signalRefresh()
    }

    private func markAll() async {
        locallyRead.formUnion(items.map(\.id))
        unreadCount = 0
        _ = try? await session.client.proNotifications.markAllRead()
        session.signalRefresh()
    }
}
