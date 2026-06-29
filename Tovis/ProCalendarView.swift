// Pro Calendar — the pro's schedule (GET /api/v1/pro/calendar), the native
// counterpart of the web `/pro/calendar`. A view switcher (Day / Week / Month,
// web `VIEW_ORDER`) over a stats header + "Pending requests" section: Month
// renders the 6×7 grid (`ProCalendarMonthGrid`); Day / Week render the agenda
// grouped by day. The visible range drives the fetch (`from`/`to`). Tapping a
// month day opens that day's agenda; tapping a booking opens its session hub.
// (The full day/week time-grid + block editing land in later increments.)
import SwiftUI
import TovisKit

struct ProCalendarView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded(ProCalendarResponse)
        case failed(String)
    }

    private enum BlockSheetTarget: Identifiable {
        case create
        case edit(ProCalendarBlock)
        var id: String {
            switch self {
            case .create: return "create"
            case let .edit(block): return "edit-\(block.id)"
            }
        }
        var sheetMode: ProBlockTimeSheet.Mode {
            switch self {
            case .create: return .create
            case let .edit(block): return .edit(block)
            }
        }
    }

    @State private var phase: Phase = .loading
    @State private var showNotifications = false
    @State private var hasUnreadNotifications = false

    // View-switcher state (web `view` / `currentDate`). The timezone is seeded
    // from the device and refined from each response's viewport zone.
    @State private var view: ProCalendarViewMode = .day   // web DEFAULT_CALENDAR_VIEW
    @State private var currentDate: Date = ProCalendarGrid.anchorNoon(Date(), timeZone: .current)
    @State private var calendarTimeZone: TimeZone = .current

    // Blocked-time CRUD (web BlockTimeModal / EditBlockModal). `locations` holds
    // the bookable locations a block can pin to; an empty list hides the FAB.
    @State private var locations: [ProLocationSummary] = []
    @State private var blockSheet: BlockSheetTarget?
    @State private var editorErrorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let stats = loadedStats { statsHeader(stats) }
                    controlsBar

                    switch phase {
                    case .loading:
                        loadingState
                    case let .failed(message):
                        errorState(message)
                    case let .loaded(data):
                        content(data)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 120)   // clear the raised footer
            }
            // "+ Block time" FAB (web MobileCalendarFab) — hidden until the pro
            // has a bookable location to pin a block to.
            .overlay(alignment: .bottomTrailing) {
                if !locations.isEmpty {
                    Button { blockSheet = .create } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(BrandColor.onAccent)
                            .frame(width: 56, height: 56)
                            .background(BrandColor.accent)
                            .clipShape(Circle())
                            .shadow(color: BrandColor.accent.opacity(0.4), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Create blocked time")
                    .padding(.trailing, 20)
                    .padding(.bottom, 104)   // clear the raised footer
                }
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .refreshable { await load() }
            .task { if case .loading = phase { await load() } }
            .task { await loadLocations() }
            // Re-fetch when the visible range changes (view switch or nav).
            .onChange(of: view) { Task { await load() } }
            .onChange(of: currentDate) { Task { await load() } }
            // Live-sync: a booking made on web (or by a client) shows here.
            .onChange(of: session.refreshTick) { Task { await load(); await loadNotificationSummary() } }
            .task { await poll() }
            .task { await loadNotificationSummary() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNotifications = true } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "bell")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(BrandColor.textPrimary)
                            if hasUnreadNotifications {
                                Circle().fill(BrandColor.accent)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 3, y: -2)
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showNotifications, onDismiss: {
                Task { await loadNotificationSummary() }
            }) {
                ProNotificationsView()
            }
            .sheet(item: $blockSheet) { target in
                ProBlockTimeSheet(
                    mode: target.sheetMode,
                    locations: locations,
                    defaultStart: defaultBlockStart,
                    timeZone: calendarTimeZone,
                    onSaved: { Task { await load() } }
                )
            }
            .alert(
                "Couldn’t open this block",
                isPresented: Binding(
                    get: { editorErrorMessage != nil },
                    set: { if !$0 { editorErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(editorErrorMessage ?? "")
            }
            .tint(BrandColor.accent)
        }
    }

    private func loadLocations() async {
        if let locs = try? await session.client.proCalendar.locations() {
            locations = locs.filter { $0.isBookable }
        }
    }

    // Default start for a new block: the selected day, bumped to the next 15-min
    // slot when that day is today (so it isn't already in the past).
    private var defaultBlockStart: Date {
        let cal = Calendar.current
        let now = Date()
        guard cal.isDate(currentDate, inSameDayAs: now) else { return currentDate }
        let minute = cal.component(.minute, from: now)
        let bump = (15 - minute % 15) % 15
        return cal.date(byAdding: .minute, value: bump == 0 ? 15 : bump, to: now) ?? now
    }

    // Tapping a block fetches its full row (for the note) then opens the editor.
    private func openBlockEditor(_ event: ProCalendarEvent) {
        Task {
            do {
                let block = try await session.client.proCalendar.block(id: event.id)
                blockSheet = .edit(block)
            } catch let error as APIError {
                editorErrorMessage = error.userMessage
            } catch {
                editorErrorMessage = "Please try again."
            }
        }
    }

    private func loadNotificationSummary() async {
        if let summary = try? await session.client.proNotifications.summary() {
            hasUnreadNotifications = summary.hasUnread
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ data: ProCalendarResponse) -> some View {
        // Pending requests are not range-scoped — they always surface (web parity).
        if !data.management.pendingRequests.isEmpty {
            BrandSection(title: "Pending requests", trailing: "\(data.management.pendingRequests.count)") {
                VStack(spacing: 10) {
                    ForEach(data.management.pendingRequests) { row(for: $0, zone: data.viewportTimeZone) }
                }
            }
        }

        if view == .month {
            monthBody(data)
        } else {
            agendaBody(data)
        }
    }

    // Month: the 6×7 grid. Tapping a day jumps to that day's agenda.
    @ViewBuilder
    private func monthBody(_ data: ProCalendarResponse) -> some View {
        let cells = ProCalendarGrid.monthCells(
            reference: currentDate, timeZone: calendarTimeZone, today: Date())
        let eventsByDay = Dictionary(grouping: data.events, by: \.localDateKey)

        ProCalendarMonthGrid(
            cells: cells,
            eventsByDay: eventsByDay,
            onPickDay: { cell in
                currentDate = ProCalendarGrid.anchorNoon(cell.startOfDay, timeZone: calendarTimeZone)
                withAnimation(.easeOut(duration: 0.15)) { view = .day }
            }
        )
    }

    // Day / Week: the agenda, grouped by day (scoped to the fetched range).
    @ViewBuilder
    private func agendaBody(_ data: ProCalendarResponse) -> some View {
        let upcoming = data.events.filter { $0.isBooking || $0.isBlock }
        if upcoming.isEmpty {
            emptyState
        } else {
            ForEach(groupedByDay(upcoming), id: \.key) { group in
                BrandSection(title: dayHeading(group.key)) {
                    VStack(spacing: 10) {
                        ForEach(group.events) { row(for: $0, zone: data.viewportTimeZone) }
                    }
                }
            }
        }
    }

    private var controlsBar: some View {
        ProCalendarControls(
            view: $view,
            headerLabel: ProCalendarGrid.headerLabel(
                view: view, reference: currentDate, timeZone: calendarTimeZone),
            onPrev: { currentDate = ProCalendarGrid.step(view: view, reference: currentDate, by: -1, timeZone: calendarTimeZone) },
            onToday: { currentDate = ProCalendarGrid.anchorNoon(Date(), timeZone: calendarTimeZone) },
            onNext: { currentDate = ProCalendarGrid.step(view: view, reference: currentDate, by: 1, timeZone: calendarTimeZone) }
        )
    }

    private var loadedStats: ProCalendarStats? {
        if case let .loaded(data) = phase { return data.stats }
        return nil
    }

    private func statsHeader(_ stats: ProCalendarStats) -> some View {
        HStack(spacing: 12) {
            statTile("\(stats.todaysBookings)", "Today")
            statTile("\(stats.pendingRequests)", "Requests")
            if let hours = stats.availableHours {
                statTile(hoursLabel(hours), "Open")
            }
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(BrandFont.display(24, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text(label.uppercased())
                    .font(BrandFont.mono(10))
                    .tracking(0.8)
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    @ViewBuilder
    private func row(for event: ProCalendarEvent, zone: String?) -> some View {
        if event.isBooking {
            NavigationLink {
                ProBookingDetailView(bookingId: event.id)
            } label: {
                ProCalendarEventRow(event: event, zone: zone)
            }
            .buttonStyle(.plain)
        } else {
            Button { openBlockEditor(event) } label: {   // a block opens its editor
                ProCalendarEventRow(event: event, zone: zone)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Grouping

    private struct DayGroup { let key: String; let events: [ProCalendarEvent] }

    private func groupedByDay(_ events: [ProCalendarEvent]) -> [DayGroup] {
        let sorted = events.sorted { $0.startsAt < $1.startsAt }
        var order: [String] = []
        var byDay: [String: [ProCalendarEvent]] = [:]
        for e in sorted {
            if byDay[e.localDateKey] == nil { order.append(e.localDateKey) }
            byDay[e.localDateKey, default: []].append(e)
        }
        return order.map { DayGroup(key: $0, events: byDay[$0] ?? []) }
    }

    /// "YYYY-MM-DD" → "Wed, Jul 15" (or "Today" / "Tomorrow").
    private func dayHeading(_ key: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: key) else { return key }

        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }

        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US")
        out.dateFormat = "EEE, MMM d"
        return out.string(from: date)
    }

    private func hoursLabel(_ hours: Double) -> String {
        hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }

    // MARK: - States

    private var loadingState: some View {
        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
            .padding(.top, 80)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Nothing on the books")
                .font(BrandFont.display(20, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("New bookings and requests will appear here.")
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    // MARK: - Load

    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { await load() }
        }
    }

    private func load() async {
        let range = ProCalendarGrid.fetchRange(
            view: view, reference: currentDate, timeZone: calendarTimeZone)
        do {
            let data = try await session.client.proCalendar.calendar(
                from: ProCalendarGrid.iso(range.from),
                to: ProCalendarGrid.iso(range.to))
            // Refine the working zone from the server's viewport (no re-fetch:
            // events carry `localDateKey`, so grouping/dots stay correct).
            if let id = data.viewportTimeZone ?? data.timeZone,
               let zone = TimeZone(identifier: id) {
                calendarTimeZone = zone
            }
            phase = .loaded(data)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your calendar. Please try again.")
        }
    }
}

// MARK: - Row

private struct ProCalendarEventRow: View {
    let event: ProCalendarEvent
    let zone: String?

    var body: some View {
        BrandSurface {
            HStack(spacing: 12) {
                BrandAvatar(name: event.clientName, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    Text(Wire.dateTime(event.startsAt, timeZone: event.timeZone ?? zone))
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                    if event.isBooking {
                        Text(event.clientName)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    BrandPill(text: statusLabel, tint: statusTone(event.status))
                    if event.isBooking {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }
            }
        }
    }

    private var statusLabel: String {
        if event.isBlock { return "Blocked" }
        return event.status.capitalized
    }
}
