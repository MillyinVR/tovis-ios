// Notifications — the client's in-app notification center (GET /api/v1/client/
// notifications). A native list of every notification (bookings, reminders,
// payments, aftercare, social), grouped into Today / Yesterday / "Thu, Jun 28"
// sections with per-day counts, filterable by category chips (All · Unread ·
// Bookings · Payments · Social), with an unread dot, a per-row mark-read on tap,
// "Mark all read", pull-to-refresh, and cursor pagination. Booking notifications
// push into the read-only BookingDetailView.
//
// Mirrors the web client notifications page (app/client/(gated)/notifications):
// same day-grouping (Today/Yesterday/"EEE, MMM d") and the same category chips
// (CATEGORY_EVENT_KEYS). Marking read here is the same backend state, so the web
// stays in step. Presented as a sheet from the Home header bell.
import SwiftUI
import TovisKit

struct NotificationsView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Web filter categories, in the web client page's chip order.
    private enum Filter: String, CaseIterable, Identifiable {
        case all, unread, bookings, payments, social
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .unread: return "Unread"
            case .bookings: return "Bookings"
            case .payments: return "Payments"
            case .social: return "Social"
            }
        }
        /// The event-category this chip filters to (nil = no category filter).
        var category: String? {
            switch self {
            case .bookings: return "BOOKINGS"
            case .payments: return "PAYMENTS"
            case .social: return "SOCIAL"
            default: return nil
            }
        }
    }

    private enum Phase {
        case loading
        case loaded([ClientNotification])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var nextCursor: String?
    @State private var loadingMore = false
    @State private var filter: Filter = .all
    /// Ids marked read locally this session (optimistic, survives until refetch).
    @State private var locallyRead: Set<String> = []
    @State private var markingAll = false
    /// Resolved bookings, keyed by id — populated lazily so a booking row can push detail.
    @State private var bookingsById: [String: ClientBooking] = [:]
    @State private var selectedBooking: ClientBooking?
    @State private var pushBooking = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView().tint(BrandColor.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message):
                    errorState(message)
                case let .loaded(items):
                    if items.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 0) {
                            chips
                            Divider().overlay(BrandColor.textMuted.opacity(0.12))
                            if visible.isEmpty { filteredEmptyState } else { list }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if hasUnread {
                        Button(action: { Task { await markAllRead() } }) {
                            Text("Mark all read")
                                .font(BrandFont.body(13, .semibold))
                                .foregroundStyle(BrandColor.accent)
                        }
                        .disabled(markingAll)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                    .accessibilityLabel("Notification settings")
                }
            }
            .navigationDestination(isPresented: $pushBooking) {
                if let booking = selectedBooking {
                    BookingDetailView(booking: booking)
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                NotificationPreferencesView()
            }
            .refreshable { await load() }
            .task { if case .loading = phase { await load() } }
            .onChange(of: session.refreshTick) { Task { await load() } }
        }
        .tint(BrandColor.accent)
    }

    private var loadedItems: [ClientNotification] {
        if case let .loaded(items) = phase { return items }
        return []
    }

    /// Loaded items after the active category filter (Unread is a server filter,
    /// so `.loaded` already holds only unread rows when that chip is active).
    private var visible: [ClientNotification] {
        guard let category = filter.category else { return loadedItems }
        return loadedItems.filter { Self.category(of: $0.eventKey) == category }
    }

    private var hasUnread: Bool {
        loadedItems.contains { isUnread($0) }
    }

    private var unreadCount: Int {
        loadedItems.filter { isUnread($0) }.count
    }

    private func isUnread(_ item: ClientNotification) -> Bool {
        item.isUnread && !locallyRead.contains(item.id)
    }

    // MARK: - Chips

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { f in
                    if f != .unread || unreadCount > 0 {
                        chip(f)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(DayGrouping.byDay(visible, date: createdAt), id: \.key) { group in
                    sectionHeader(group.day, count: group.items.count)
                    ForEach(group.items) { item in
                        Button(action: { Task { await tap(item) } }) {
                            NotificationRow(item: item, unread: isUnread(item))
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            // Category filters are client-side over the loaded feed,
                            // so only auto-page on All / Unread (mirrors the pro view).
                            if filter.category == nil, item.id == visible.last?.id {
                                Task { await loadMore() }
                            }
                        }
                    }
                }

                if loadingMore {
                    ProgressView().tint(BrandColor.accent).padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
    }

    private func sectionHeader(_ day: Date, count: Int) -> some View {
        HStack {
            Text(DayGrouping.heading(for: day))
                .font(BrandFont.mono(11)).tracking(0.5)
                .foregroundStyle(BrandColor.textMuted)
            Spacer()
            Text(count == 1 ? "1 item" : "\(count) items")
                .font(BrandFont.mono(10))
                .foregroundStyle(BrandColor.textMuted)
        }
        .padding(.top, 8).padding(.bottom, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bell.slash")
                .font(.system(size: 30))
                .foregroundStyle(BrandColor.textMuted)
            Text("You're all caught up")
                .font(BrandFont.display(18, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("Bookings, reminders, and updates will show up here.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 8) {
            Text("Nothing in \(filter.label)")
                .font(BrandFont.body(15, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("Try a different filter.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textMuted)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(BrandColor.accent)
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Category mapping (web parity — CATEGORY_EVENT_KEYS)

    /// Event → category, matching the web client page's CATEGORY_EVENT_KEYS.
    /// Uncategorized events (nil) only surface under All.
    private static func category(of eventKey: String) -> String? {
        switch eventKey {
        case "BOOKING_CONFIRMED", "BOOKING_RESCHEDULED",
             "BOOKING_CANCELLED_BY_CLIENT", "BOOKING_CANCELLED_BY_PRO",
             "BOOKING_CANCELLED_BY_ADMIN", "CONSULTATION_PROPOSAL_SENT",
             "CONSULTATION_APPROVED", "CONSULTATION_REJECTED",
             "CLIENT_CLAIM_INVITE", "APPOINTMENT_REMINDER", "AFTERCARE_READY",
             "LAST_MINUTE_OPENING_AVAILABLE":
            return "BOOKINGS"
        case "PAYMENT_COLLECTED", "PAYMENT_ACTION_REQUIRED", "PAYMENT_REFUNDED":
            return "PAYMENTS"
        case "REVIEW_RECEIVED", "VIRAL_REQUEST_APPROVED", "LOOK_FOLLOWER_NEW",
             "CLIENT_FOLLOW", "LOOK_COMMENTED", "LOOK_COMMENT_REPLIED",
             "LOOK_LIKED", "LOOK_SAVED", "LOOK_NEW_FROM_FOLLOWED_PRO",
             "REFERRAL_TAP_RECEIVED", "REFERRAL_CONFIRMED", "REFERRAL_CONVERTED":
            return "SOCIAL"
        default:
            return nil
        }
    }

    // MARK: - Date grouping (web parity — Today / Yesterday / "EEE, MMM d")

    /// The one thing the shared grouper can't know: where the timestamp lives on
    /// this screen's element, and what an unparseable one should fall back to.
    private func createdAt(_ item: ClientNotification) -> Date {
        Wire.date(item.createdAt) ?? Date()
    }

    // MARK: - Data

    private func select(_ f: Filter) async {
        filter = f
        // Unread is a server filter; categories are client-side over the loaded feed.
        if f == .all || f == .unread { await load() }
    }

    private func load() async {
        do {
            let page = try await session.client.notifications.feed(
                unreadOnly: filter == .unread, take: 50
            )
            nextCursor = page.nextCursor
            phase = .loaded(page.items)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn't load notifications.")
        }
    }

    private func loadMore() async {
        guard let cursor = nextCursor, !loadingMore else { return }
        guard case let .loaded(current) = phase else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await session.client.notifications.feed(
                unreadOnly: filter == .unread, cursor: cursor, take: 50
            )
            nextCursor = page.nextCursor
            phase = .loaded(current + page.items)
        } catch {
            // Keep what we have; the next scroll/refresh retries.
        }
    }

    private func markAllRead() async {
        guard hasUnread, !markingAll else { return }
        markingAll = true
        defer { markingAll = false }
        // Optimistic: clear every unread dot now.
        locallyRead.formUnion(loadedItems.map(\.id))
        do {
            _ = try await session.client.notifications.markRead()
            session.signalRefresh() // refresh the Home bell + other surfaces
        } catch {
            locallyRead.removeAll() // roll back so the user can retry
        }
    }

    private func tap(_ item: ClientNotification) async {
        if isUnread(item) {
            locallyRead.insert(item.id)
            Task {
                _ = try? await session.client.notifications.markRead(ids: [item.id])
                session.signalRefresh()
            }
        }
        if let bookingId = item.bookingId {
            await openBooking(bookingId)
            return
        }
        // No booking to push, but the row still carries a destination (a look, an
        // offer, referrals, a message thread). Hand the href to the same channel a
        // tapped push uses and let the shell beneath route it — `ClaimView` does
        // this too. Unroutable paths fall through so the tap stays a mark-read
        // rather than dismissing this sheet onto nothing.
        guard item.deepLink != nil else { return }
        session.handlePushDeepLink(href: item.href)
        dismiss()
    }

    /// Resolve a booking id to its full ClientBooking (cached) and push detail.
    private func openBooking(_ bookingId: String) async {
        if let cached = bookingsById[bookingId] {
            selectedBooking = cached
            pushBooking = true
            return
        }
        guard let buckets = try? await session.client.bookings.fetch() else { return }
        let all = buckets.upcoming + buckets.pending + buckets.prebooked + buckets.past
        var map: [String: ClientBooking] = [:]
        for booking in all { map[booking.id] = booking }
        bookingsById = map
        if let booking = map[bookingId] {
            selectedBooking = booking
            pushBooking = true
        }
    }
}

// MARK: - Row

private struct NotificationRow: View {
    let item: ClientNotification
    let unread: Bool

    var body: some View {
        let style = NotificationStyle.forEvent(item.eventKey)
        BrandSurface(tint: unread ? BrandColor.bgSurface : BrandColor.bgSecondary) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(style.tint.opacity(0.14)).frame(width: 38, height: 38)
                    Image(systemName: style.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(style.tint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title)
                            .font(BrandFont.body(14, unread ? .semibold : .regular))
                            .foregroundStyle(BrandColor.textPrimary)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Text(Self.timeLabel(item.createdAt))
                            .font(BrandFont.mono(10))
                            .foregroundStyle(BrandColor.textMuted)
                        if unread {
                            Circle().fill(BrandColor.accent).frame(width: 7, height: 7)
                        }
                    }
                    if let body = item.body, !body.isEmpty {
                        Text(body)
                            .font(BrandFont.body(12.5))
                            .foregroundStyle(BrandColor.textSecondary)
                            .lineLimit(3)
                    }
                }
            }
        }
    }

    /// ISO instant → "2:45 PM" (the day is carried by the section header).
    private static func timeLabel(_ iso: String) -> String {
        guard let d = Wire.date(iso) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }
}

/// SF Symbol + tint for a notification, derived from its `NotificationEventKey`.
private struct NotificationStyle {
    let symbol: String
    let tint: Color

    static func forEvent(_ eventKey: String) -> NotificationStyle {
        switch eventKey {
        case "BOOKING_CONFIRMED", "BOOKING_REQUEST_CREATED", "BOOKING_STARTED",
             "BOOKING_RESCHEDULED":
            return .init(symbol: "calendar", tint: BrandColor.accent)
        case "BOOKING_CANCELLED_BY_CLIENT", "BOOKING_CANCELLED_BY_PRO",
             "BOOKING_CANCELLED_BY_ADMIN":
            return .init(symbol: "calendar.badge.minus", tint: BrandColor.ember)
        case "CONSULTATION_PROPOSAL_SENT", "CONSULTATION_APPROVED",
             "CONSULTATION_REJECTED", "CLIENT_CLAIM_INVITE":
            return .init(symbol: "text.bubble", tint: BrandColor.gold)
        case "APPOINTMENT_REMINDER":
            return .init(symbol: "bell.badge", tint: BrandColor.accent)
        case "AFTERCARE_READY":
            return .init(symbol: "heart.text.square", tint: BrandColor.iris)
        case "PAYMENT_COLLECTED", "PAYMENT_REFUNDED":
            return .init(symbol: "creditcard", tint: BrandColor.emerald)
        case "PAYMENT_ACTION_REQUIRED":
            return .init(symbol: "exclamationmark.circle", tint: BrandColor.amber)
        case "LAST_MINUTE_OPENING_AVAILABLE":
            return .init(symbol: "bolt.fill", tint: BrandColor.gold)
        case "REVIEW_RECEIVED", "VIRAL_REQUEST_APPROVED":
            return .init(symbol: "star.fill", tint: BrandColor.gold)
        case "REVIEW_REQUESTED":
            return .init(symbol: "star.bubble", tint: BrandColor.gold)
        case "LOOK_FOLLOWER_NEW", "CLIENT_FOLLOW":
            return .init(symbol: "person.badge.plus", tint: BrandColor.iris)
        case "LOOK_COMMENTED", "LOOK_COMMENT_REPLIED":
            return .init(symbol: "bubble.left", tint: BrandColor.accent)
        case "LOOK_LIKED":
            return .init(symbol: "heart.fill", tint: BrandColor.ember)
        case "LOOK_SAVED":
            return .init(symbol: "bookmark.fill", tint: BrandColor.gold)
        case "LOOK_NEW_FROM_FOLLOWED_PRO":
            return .init(symbol: "sparkles", tint: BrandColor.iris)
        case "REFERRAL_TAP_RECEIVED", "REFERRAL_CONFIRMED", "REFERRAL_CONVERTED":
            return .init(symbol: "gift", tint: BrandColor.accent)
        default:
            return .init(symbol: "bell", tint: BrandColor.accent)
        }
    }
}
