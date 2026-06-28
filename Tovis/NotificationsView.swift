// Notifications — the client's in-app notification center (GET /api/v1/client/
// notifications). A native list of every notification (bookings, reminders,
// payments, aftercare, social), newest first, with an unread dot, a per-row
// mark-read on tap, "Mark all read", pull-to-refresh, and cursor pagination.
// Booking notifications push into the read-only BookingDetailView.
//
// Mirrors the same ClientNotification rows the web surfaces (the Activity feed +
// pro notification cards) — marking read here is the same backend state, so the
// web stays in step. Presented as a sheet from the Home header bell.
import SwiftUI
import TovisKit

struct NotificationsView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case loaded([ClientNotification])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var nextCursor: String?
    @State private var loadingMore = false
    /// Ids marked read locally this session (optimistic, survives until refetch).
    @State private var locallyRead: Set<String> = []
    @State private var markingAll = false
    /// Resolved bookings, keyed by id — populated lazily so a booking row can push detail.
    @State private var bookingsById: [String: ClientBooking] = [:]
    @State private var selectedBooking: ClientBooking?
    @State private var pushBooking = false

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
                    if items.isEmpty { emptyState } else { list(items) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.large)
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
            }
            .navigationDestination(isPresented: $pushBooking) {
                if let booking = selectedBooking {
                    BookingDetailView(booking: booking)
                }
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

    private var hasUnread: Bool {
        loadedItems.contains { isUnread($0) }
    }

    private func isUnread(_ item: ClientNotification) -> Bool {
        item.isUnread && !locallyRead.contains(item.id)
    }

    // MARK: - List

    private func list(_ items: [ClientNotification]) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(items) { item in
                    Button(action: { Task { await tap(item) } }) {
                        NotificationRow(item: item, unread: isUnread(item))
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if item.id == items.last?.id { Task { await loadMore() } }
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

    // MARK: - Data

    private func load() async {
        do {
            let page = try await session.client.notifications.feed(take: 50)
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
            let page = try await session.client.notifications.feed(cursor: cursor, take: 50)
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
        }
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
                        Text(Wire.relativeAgo(item.createdAt))
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
        case "LOOK_FOLLOWER_NEW", "CLIENT_FOLLOW":
            return .init(symbol: "person.badge.plus", tint: BrandColor.iris)
        case "REFERRAL_TAP_RECEIVED", "REFERRAL_CONFIRMED", "REFERRAL_CONVERTED":
            return .init(symbol: "gift", tint: BrandColor.accent)
        default:
            return .init(symbol: "bell", tint: BrandColor.accent)
        }
    }
}
