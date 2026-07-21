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

    /// Returns to the Overview home (the footer has no Overview slot). Supplied
    /// by `ProMainTabView`; nil when the calendar is shown standalone.
    var onHome: (() -> Void)? = nil

    private enum Phase {
        case loading
        case loaded(ProCalendarResponse)
        case failed(String)
    }

    private enum BlockSheetTarget: Identifiable {
        /// `start` pins the sheet to a tapped empty slot; nil = defaultBlockStart.
        case create(start: Date?)
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
        var createStart: Date? {
            if case let .create(start) = self { return start }
            return nil
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
    // The pro's weekly working hours, one per bookable location TYPE (salon +
    // mobile base) — drives the day/week grid's off-hours shading, which dims the
    // hours OUTSIDE the union of these windows (web merges salon + mobile). Empty
    // until loaded (no shading); usually one entry (single-location pro).
    @State private var workingWeeks: [ProWeekHours] = []
    @State private var blockSheet: BlockSheetTarget?
    // The "+" FAB opens this chooser: add an appointment or block personal time
    // (web MobileCalendarFab + CalendarCreateSheet).
    @State private var showCreateChooser = false
    // Tapping an empty grid slot opens the same chooser pinned to that instant
    // (web click-to-create CalendarCreateSheet). Non-nil = chooser presented.
    @State private var emptySlotChoice: Date?
    @State private var editorErrorMessage: String?

    // Auto-accept toggle + active-location filter + pending-request quick actions
    // (web MobileAutoAcceptBar / MobileLocationBar / MobilePendingRequestBar).
    @State private var autoAccept = false
    @State private var savingAutoAccept = false
    @State private var activeLocationId: String?
    @State private var pendingDismissedKey: String?
    @State private var pendingActionBusyId: String?
    @State private var pendingActionError: String?

    // Programmatic push to a booking's detail when a time-grid tile is tapped.
    private struct BookingNav: Identifiable, Hashable { let id: String }
    @State private var bookingNav: BookingNav?

    // Programmatic push to the new-booking form, prefilled to a tapped empty slot.
    private struct NewBookingNav: Identifiable, Hashable {
        let id = UUID()
        let date: Date
    }
    @State private var newBookingNav: NewBookingNav?

    // Collapses the stats / location / auto-accept chrome to give the grid room.
    @State private var chromeCollapsed = false

    // Drag-to-reschedule + bottom-edge resize (web `useDragDrop` + `useConfirmChange`):
    // the time-grid sets `pendingMove` (dropped on a new time) or `pendingResize`
    // (bottom edge dragged to a new length); we confirm the change, then PATCH
    // /pro/bookings/{id} — a move via `reschedule` (new `scheduledFor`), a resize via
    // `resizeDuration` (new `durationMinutes`) — reusing the same override "save it
    // anyway?" retry as ProRescheduleView (intent `.edit`). Only one change is ever
    // in flight, so the confirm / override / idempotency state below is shared.
    @State private var pendingMove: PendingCalendarMove?
    @State private var pendingResize: PendingCalendarResize?
    @State private var showChangeConfirm = false
    @State private var changeSubmitting = false
    @State private var changeError: String?
    // Idempotency + override carry-over, mirroring ProRescheduleView's contract.
    @State private var changeAttemptKey: String?
    @State private var changeAppliedOverrides: Set<BookingOverrideFlag> = []
    @State private var changeOverridePrompt: BookingOverridePrompt?
    @State private var changeOverrideReason = ""

    // Management sheet (web ManagementModal): tapping a stats tile opens the
    // Booked / Pending / Blocked / Waitlist lists. Block edit/add is routed back
    // here (a block editor is itself a sheet) via `pendingManagementAction`.
    @State private var managementTab: ProCalendarManagementTab?
    private enum PendingManagementAction { case editBlock(ProCalendarBlock), addBlock }
    @State private var pendingManagementAction: PendingManagementAction?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Pinned top chrome. Stats / location collapse to free grid space;
                // the view switcher + date nav stay so you can always navigate.
                VStack(alignment: .leading, spacing: 14) {
                    if !chromeCollapsed, let data = loadedData { statsHeader(data) }
                    controlsBar

                    if !chromeCollapsed, locations.count > 1 {
                        ProLocationBar(
                            locations: locations,
                            activeLocationId: activeLocationId,
                            onChange: { activeLocationId = $0 }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)

                // Body fills the remaining height (day/week grid scrolls itself).
                switch phase {
                case .loading:
                    Spacer(); loadingState; Spacer()
                case let .failed(message):
                    Spacer(); errorState(message); Spacer()
                case let .loaded(data):
                    content(data)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // "+" FAB (web MobileCalendarFab + CalendarCreateSheet) — opens a
            // chooser to add an appointment or block personal time. Hidden until
            // the pro has a bookable location (an appointment needs one; a block
            // pins to one).
            .overlay(alignment: .bottomTrailing) {
                if !locations.isEmpty {
                    Button { showCreateChooser = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(BrandColor.onAccent)
                            .frame(width: 56, height: 56)
                            .background(BrandColor.accent)
                            .clipShape(Circle())
                            .shadow(color: BrandColor.accent.opacity(0.4), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add to calendar")
                    .padding(.trailing, 20)
                    .padding(.bottom, 104)   // clear the raised footer
                }
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Calendar")
            // Inline (not large) title keeps the chrome compact so the time-grid
            // gets more vertical room.
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .refreshable { await load() }
            .task { if case .loading = phase { await load() } }
            .task { await loadLocations() }
            // Re-fetch when the visible range changes (view switch or nav).
            .onChange(of: view) { Task { await load() } }
            .onChange(of: currentDate) { Task { await load() } }
            .onChange(of: activeLocationId) { Task { await load() } }
            // Live-sync: a booking made on web (or by a client) shows here.
            .onChange(of: session.refreshTick) { Task { await load(); await loadNotificationSummary() } }
            .task { await poll() }
            .task { await loadNotificationSummary() }
            .toolbar {
                if let onHome {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { onHome() } label: {
                            Image(systemName: "house")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                        }
                        .accessibilityLabel("Overview home")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { chromeCollapsed.toggle() }
                    } label: {
                        Image(systemName: chromeCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                    }
                    .accessibilityLabel(chromeCollapsed ? "Expand details" : "Collapse details")
                }
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
            .navigationDestination(item: $bookingNav) { nav in
                ProBookingDetailView(bookingId: nav.id)
            }
            .navigationDestination(item: $newBookingNav) { nav in
                ProNewBookingView(
                    onCreated: { _ in Task { await load() } },
                    prefillDate: nav.date
                )
            }
            .sheet(item: $blockSheet) { target in
                ProBlockTimeSheet(
                    mode: target.sheetMode,
                    locations: locations,
                    defaultStart: target.createStart ?? defaultBlockStart,
                    timeZone: calendarTimeZone,
                    onSaved: { Task { await load() } }
                )
            }
            // Management sheet (web ManagementModal). Block edit/add is deferred to
            // this sheet's onDismiss so the block editor (itself a sheet) doesn't
            // race the dismissal.
            .sheet(item: $managementTab, onDismiss: runPendingManagementAction) { tab in
                if let data = loadedData {
                    ProCalendarManagementSheet(
                        events: data.events,
                        management: data.management,
                        timeZone: data.viewportTimeZone,
                        headerLabel: ProCalendarGrid.headerLabel(
                            view: view, reference: currentDate, timeZone: calendarTimeZone),
                        onReload: { await load() },
                        onEditBlock: openBlockFromManagement,
                        onAddBlock: {
                            pendingManagementAction = .addBlock
                            managementTab = nil
                        },
                        selectedTab: tab
                    )
                }
            }
            // The "+" chooser: both branches reuse existing flows — the new-booking
            // form (prefilled to the viewed day) and the block-time sheet.
            .confirmationDialog(
                "Add to your calendar",
                isPresented: $showCreateChooser,
                titleVisibility: .visible
            ) {
                Button("Add appointment") {
                    newBookingNav = NewBookingNav(date: defaultBlockStart)
                }
                Button("Block personal time") {
                    blockSheet = .create(start: nil)
                }
                Button("Cancel", role: .cancel) {}
            }
            // Empty-slot tap chooser: same two branches, pinned to the tapped
            // instant so both the booking form and the block sheet open there.
            .confirmationDialog(
                emptySlotChoiceTitle,
                isPresented: Binding(
                    get: { emptySlotChoice != nil },
                    set: { if !$0 { emptySlotChoice = nil } }
                ),
                titleVisibility: .visible,
                presenting: emptySlotChoice
            ) { date in
                Button("Add appointment") {
                    newBookingNav = NewBookingNav(date: date)
                }
                Button("Block personal time") {
                    blockSheet = .create(start: date)
                }
                Button("Cancel", role: .cancel) {}
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
            // Drag-move / resize confirm / override / error alerts (extracted to a
            // ViewModifier so this already-large body still type-checks in time).
            .modifier(CalendarChangeAlerts(
                pendingMove: $pendingMove,
                pendingResize: $pendingResize,
                showChangeConfirm: $showChangeConfirm,
                changeOverridePrompt: $changeOverridePrompt,
                changeOverrideReason: $changeOverrideReason,
                changeError: $changeError,
                title: changeConfirmTitle,
                confirmLabel: changeConfirmButton,
                message: changeConfirmMessage,
                onConfirm: beginChange,
                onOverride: confirmChangeOverride,
                onCancel: cancelChange
            ))
            .tint(BrandColor.accent)
        }
    }

    private func loadLocations() async {
        guard let locs = try? await session.client.proCalendar.locations() else { return }
        let bookable = locs.filter { $0.isBookable }
        locations = bookable
        await loadWorkingHours(from: bookable)
    }

    /// Load each bookable location TYPE's weekly hours for the grid's off-hours
    /// shading. The grid dims the hours outside the UNION of these windows (web
    /// merges salon + mobile), so a dual-location pro who works the salon by day
    /// and mobile in the evening sees both windows un-shaded. Picks the primary
    /// bookable location for each type present (salon vs mobile base) — filtered to
    /// bookable, so a mobile-only pro's archived salon never adds a phantom window.
    /// A single-location pro yields one week, identical to the old behavior.
    private func loadWorkingHours(from bookable: [ProLocationSummary]) async {
        let salon = bookable.first(where: { $0.isPrimary && !$0.isMobileBase })
            ?? bookable.first(where: { !$0.isMobileBase })
        let mobile = bookable.first(where: { $0.isPrimary && $0.isMobileBase })
            ?? bookable.first(where: { $0.isMobileBase })
        let targets = [salon, mobile].compactMap { $0 }
        guard !targets.isEmpty else {
            workingWeeks = []
            return
        }
        var weeks: [ProWeekHours] = []
        for loc in targets {
            if let res = try? await session.client.proSchedule.workingHours(
                locationType: ProWorkingHours.mode(for: loc), locationId: loc.id) {
                weeks.append(res.workingHours)
            }
        }
        workingWeeks = weeks
    }

    // Chooser title for a tapped empty slot, e.g.
    // "Add to your calendar · Tue, Jul 21, 2:30 PM" (in the calendar's zone).
    private var emptySlotChoiceTitle: String {
        guard let date = emptySlotChoice else { return "Add to your calendar" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = calendarTimeZone
        f.dateFormat = "EEE, MMM d, h:mm a"
        return "Add to your calendar · " + f.string(from: date)
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
                let block = try await session.client.proCalendar.block(id: event.calendarBlockId)
                blockSheet = .edit(block)
            } catch let error as APIError {
                editorErrorMessage = error.userMessage
            } catch {
                editorErrorMessage = "Please try again."
            }
        }
    }

    // Editing a block from the management sheet: fetch the full row, stash the
    // intent, then dismiss the management sheet — the editor opens in onDismiss.
    private func openBlockFromManagement(_ event: ProCalendarEvent) {
        Task {
            do {
                let block = try await session.client.proCalendar.block(id: event.calendarBlockId)
                pendingManagementAction = .editBlock(block)
            } catch let error as APIError {
                editorErrorMessage = error.userMessage
            } catch {
                editorErrorMessage = "Please try again."
            }
            managementTab = nil
        }
    }

    // Runs after the management sheet fully dismisses so the block editor (a
    // sheet) never overlaps it.
    private func runPendingManagementAction() {
        let action = pendingManagementAction
        pendingManagementAction = nil
        switch action {
        case .addBlock:
            blockSheet = .create(start: nil)
        case let .editBlock(block):
            blockSheet = .edit(block)
        case .none:
            break
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
        if view == .month {
            // Month is short; let it scroll within the remaining space.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    pendingBar(data)
                    if !chromeCollapsed {
                        ProAutoAcceptBar(enabled: autoAccept, saving: savingAutoAccept, onToggle: toggleAutoAccept)
                    }
                    monthBody(data)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 110)
            }
        } else {
            // Day/Week: the time-grid fills the remaining height and scrolls
            // internally, opening at "now" — the chrome above stays visible.
            VStack(spacing: 10) {
                pendingBar(data)
                if !chromeCollapsed {
                    ProAutoAcceptBar(enabled: autoAccept, saving: savingAutoAccept, onToggle: toggleAutoAccept)
                }
                ProCalendarTimeGrid(
                    view: view,
                    currentDate: currentDate,
                    timeZone: calendarTimeZone,
                    events: data.events,
                    onTapBooking: { id in bookingNav = BookingNav(id: id) },
                    onTapBlock: { event in openBlockEditor(event) },
                    onTapEmptySlot: { date in emptySlotChoice = date },
                    collapseToggle: chromeCollapsed,
                    workingWeeks: workingWeeks,
                    pendingMove: $pendingMove,
                    pendingResize: $pendingResize,
                    // Cross-week drag: dwelling a lifted tile at the grid's edge pages
                    // one week. Shifts `currentDate` (same `step` the nav buttons use)
                    // → `.onChange` refetches; the drag survives (grid `@State`).
                    onEdgePage: { delta in
                        currentDate = ProCalendarGrid.step(
                            view: .week, reference: currentDate, by: delta, timeZone: calendarTimeZone)
                    }
                )
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 20)
            // Extend the grid down to the footer-bar top; the raised (transparent)
            // START coin lifts above the bar and is allowed to overlap the grid.
            .padding(.bottom, 6)
        }
    }

    // Month: the 6×7 grid. Tapping a day jumps to that day's time-grid.
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

    private var loadedData: ProCalendarResponse? {
        if case let .loaded(data) = phase { return data }
        return nil
    }

    // Web parity (CalendarStatsPanel): Booked / Pending / (Waitlist) / Free with
    // sub-labels. Each tile opens the management sheet on its matching tab — the
    // Waitlist tile only appears when clients are waiting.
    private func statsHeader(_ data: ProCalendarResponse) -> some View {
        let stats = data.stats
        return HStack(spacing: 10) {
            statTile("\(stats.todaysBookings)", "Booked", "today", tab: .booked)
            statTile("\(stats.pendingRequests)", "Pending", "review", tab: .pending)
            if !data.management.waitlistToday.isEmpty {
                statTile(
                    "\(data.management.waitlistToday.count)", "Waitlist", "people", tab: .waitlist)
            }
            statTile(
                stats.availableHours.map(hoursLabel) ?? "—",
                "Free",
                "\(hoursLabel(stats.blockedHours)) blocked",
                tab: .blocked)
        }
    }

    private func statTile(
        _ value: String, _ label: String, _ sub: String, tab: ProCalendarManagementTab
    ) -> some View {
        Button { managementTab = tab } label: {
            BrandSurface {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label.uppercased())
                        .font(BrandFont.mono(10))
                        .tracking(0.8)
                        .foregroundStyle(BrandColor.textMuted)
                    Text(value)
                        .font(BrandFont.display(24, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(sub)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(value), \(sub)")
    }

    // The top pending request with quick approve/deny (web MobilePendingRequestBar).
    // Approving advances to the next; "+N more" counts the rest.
    @ViewBuilder
    private func pendingBar(_ data: ProCalendarResponse) -> some View {
        let pending = data.management.pendingRequests
        let key = pending.map(\.id).joined(separator: "|")
        if let top = pending.first, pendingDismissedKey != key {
            ProPendingRequestBar(
                event: top,
                moreCount: pending.count - 1,
                timeZone: data.viewportTimeZone,
                busy: pendingActionBusyId == top.id,
                errorText: pendingActionError,
                onOpen: { bookingNav = BookingNav(id: top.id) },
                onApprove: { approvePending(top) },
                onDeny: { denyPending(top) },
                onDismiss: { pendingDismissedKey = key }
            )
        }
    }

    private func toggleAutoAccept() {
        guard !savingAutoAccept else { return }
        let next = !autoAccept
        savingAutoAccept = true
        autoAccept = next   // optimistic
        Task {
            do {
                autoAccept = try await session.client.proCalendar.setAutoAccept(next)
            } catch {
                autoAccept = !next   // revert on failure
            }
            savingAutoAccept = false
        }
    }

    private func approvePending(_ event: ProCalendarEvent) {
        runPendingAction(event) {
            try await session.client.proBookings.accept(bookingId: event.id)
        }
    }

    private func denyPending(_ event: ProCalendarEvent) {
        runPendingAction(event) {
            try await session.client.proBookings.decline(bookingId: event.id)
        }
    }

    private func runPendingAction(
        _ event: ProCalendarEvent,
        _ action: @escaping () async throws -> Void
    ) {
        guard pendingActionBusyId == nil else { return }
        pendingActionBusyId = event.id
        pendingActionError = nil
        Task {
            do {
                try await action()
                await load()
            } catch let error as APIError {
                pendingActionError = error.userMessage
            } catch {
                pendingActionError = "Please try again."
            }
            pendingActionBusyId = nil
        }
    }

    private func hoursLabel(_ hours: Double) -> String {
        hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }

    // MARK: - States

    private var loadingState: some View {
        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
            .padding(.top, 80)
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
                to: ProCalendarGrid.iso(range.to),
                locationId: activeLocationId)
            // Refine the working zone from the server's viewport (no re-fetch:
            // events carry `localDateKey`, so grouping/dots stay correct).
            if let id = data.viewportTimeZone ?? data.timeZone,
               let zone = TimeZone(identifier: id) {
                calendarTimeZone = zone
            }
            // Seed the auto-accept toggle from the server (unless a save is mid-flight).
            if !savingAutoAccept, let aa = data.autoAcceptBookings {
                autoAccept = aa
            }
            phase = .loaded(data)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your calendar. Please try again.")
        }
    }

    // MARK: - Calendar change (drag-move / bottom-edge resize)

    /// The change currently awaiting confirm/submit — a move or a resize (only one
    /// is ever pending). Derived from whichever optimistic binding the grid set.
    private var pendingChange: PendingCalendarChange? {
        if let move = pendingMove { return .move(move) }
        if let resize = pendingResize { return .resize(resize) }
        return nil
    }

    /// Confirm-alert title / primary-button label — the action being confirmed.
    private func changeConfirmTitle(_ change: PendingCalendarChange) -> String {
        switch change {
        case let .move(move): return move.event.isBlock ? "Move blocked time" : "Move appointment"
        case .resize: return "Change duration"
        }
    }

    private func changeConfirmButton(_ change: PendingCalendarChange) -> String {
        changeConfirmTitle(change)
    }

    /// What the change is acting on, for the confirm copy.
    private func subjectLabel(_ event: ProCalendarEvent) -> String {
        if event.isBlock { return "this blocked time" }
        return event.clientName.isEmpty ? "this appointment" : event.clientName
    }

    /// Confirm-alert copy: what's changing (in the calendar's zone), plus a passive
    /// heads-up when the new window double-books another appointment.
    private func changeConfirmMessage(_ change: PendingCalendarChange) -> String {
        let who = subjectLabel(change.event)
        var message: String
        switch change {
        case let .move(move):
            message = "Move \(who) to \(moveTimeLabel(move.newStart))?"
        case let .resize(resize):
            message = "Change \(who) to \(durationLabel(resize.newDurationMinutes))?"
        }
        if let other = overlappingClientName(for: change) {
            message += "\n\nHeads up — this overlaps \(other). You can still save it."
        }
        return message
    }

    /// The client a proposed change would double-book, if any (passive — the change
    /// is still allowed; this only surfaces the overlap in the confirm). A move uses
    /// its new start + the booking's duration; a resize keeps the start and uses the
    /// new duration.
    private func overlappingClientName(for change: PendingCalendarChange) -> String? {
        guard let data = loadedData else { return nil }
        // Blocks can't passively overlap: the server hard-rejects a block that
        // collides with a booking/hold/block, so a "you can still save it" note
        // would be misleading — surface the real rejection instead.
        guard !change.event.isBlock else { return nil }

        let start: Date
        let durationMinutes: Int
        switch change {
        case let .move(move):
            start = move.newStart
            durationMinutes = max(15, move.event.durationMinutes)
        case let .resize(resize):
            guard let resizeStart = Wire.date(resize.event.startsAt) else { return nil }
            start = resizeStart
            durationMinutes = max(15, resize.newDurationMinutes)
        }

        let end = start.addingTimeInterval(Double(durationMinutes) * 60)
        for event in data.events where event.isBooking && event.id != change.event.id {
            guard let otherStart = Wire.date(event.startsAt) else { continue }
            let otherEnd = Wire.date(event.endsAt)
                ?? otherStart.addingTimeInterval(Double(max(15, event.durationMinutes)) * 60)
            if otherStart < end && start < otherEnd {
                return event.clientName.isEmpty ? "another appointment" : event.clientName
            }
        }
        return nil
    }

    private func moveTimeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = calendarTimeZone
        f.dateFormat = "EEE, MMM d · h:mm a"
        return f.string(from: date)
    }

    /// "1h 30m" / "45m" for a minutes duration — the resize confirm copy.
    private func durationLabel(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 && mins > 0 { return "\(hours)h \(mins)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(mins)m"
    }

    /// Abandon a pending change — clears the optimistic tile so it snaps back and
    /// drops any carried override state.
    private func cancelChange() {
        pendingMove = nil
        pendingResize = nil
        changeAttemptKey = nil
        changeAppliedOverrides = []
        changeOverrideReason = ""
    }

    /// The pro confirmed the change — mint one idempotency key and submit.
    private func beginChange(_ change: PendingCalendarChange) {
        guard !changeSubmitting else { return }
        changeAppliedOverrides = []
        changeOverrideReason = ""
        changeAttemptKey = UUID().uuidString
        Task { await submitChange(change) }
    }

    /// The pro approved an override-gated prompt — carry the flag and re-submit
    /// with a fresh key (the changed body is a new logical request).
    private func confirmChangeOverride(_ prompt: BookingOverridePrompt) {
        guard let change = pendingChange else { return }
        changeAppliedOverrides.insert(prompt.flag)
        changeOverridePrompt = nil
        changeAttemptKey = UUID().uuidString
        Task { await submitChange(change) }
    }

    /// PATCH the change — a move (`reschedule`, new start) or a resize
    /// (`resizeDuration`, new duration). On an override-gated rejection surface a
    /// "save it anyway?" retry (unless the flag was already applied — then it's a
    /// real failure); any other error snaps the tile back and shows an alert.
    private func submitChange(_ change: PendingCalendarChange) async {
        guard let key = changeAttemptKey else { return }
        changeSubmitting = true
        defer { changeSubmitting = false }

        let reason = changeOverrideReason.trimmingCharacters(in: .whitespacesAndNewlines)
        let overrideReason = (changeAppliedOverrides.isEmpty || reason.isEmpty) ? nil : reason
        do {
            switch change {
            case let .move(move) where move.event.isBlock:
                // Blocks move via /pro/calendar/blocked (absolute window; no
                // client-notify / override flags). Keep the duration; preserve the
                // note (omit it → server leaves it unchanged).
                let endsAt = move.newStart.addingTimeInterval(Double(max(15, move.event.durationMinutes)) * 60)
                try await session.client.proCalendar.updateBlock(
                    id: move.event.calendarBlockId,
                    startsAt: ProCalendarGrid.iso(move.newStart),
                    endsAt: ProCalendarGrid.iso(endsAt),
                    note: nil
                )
            case let .resize(resize) where resize.event.isBlock:
                // Block resize keeps the start, extends the end via the same route.
                guard let start = Wire.date(resize.event.startsAt) else {
                    changeError = "Couldn’t resize this block. Please try again."
                    cancelChange()
                    return
                }
                let endsAt = start.addingTimeInterval(Double(resize.newDurationMinutes) * 60)
                try await session.client.proCalendar.updateBlock(
                    id: resize.event.calendarBlockId,
                    startsAt: resize.event.startsAt,
                    endsAt: ProCalendarGrid.iso(endsAt),
                    note: nil
                )
            case let .move(move):
                try await session.client.proBookings.reschedule(
                    bookingId: move.event.id,
                    scheduledFor: ProCalendarGrid.iso(move.newStart),
                    notifyClient: true,
                    allowOutsideWorkingHours: changeAppliedOverrides.contains(.allowOutsideWorkingHours),
                    allowShortNotice: changeAppliedOverrides.contains(.allowShortNotice),
                    allowFarFuture: changeAppliedOverrides.contains(.allowFarFuture),
                    overrideReason: overrideReason,
                    idempotencyKey: key
                )
            case let .resize(resize):
                try await session.client.proBookings.resizeDuration(
                    bookingId: resize.event.id,
                    durationMinutes: resize.newDurationMinutes,
                    notifyClient: true,
                    allowOutsideWorkingHours: changeAppliedOverrides.contains(.allowOutsideWorkingHours),
                    allowShortNotice: changeAppliedOverrides.contains(.allowShortNotice),
                    allowFarFuture: changeAppliedOverrides.contains(.allowFarFuture),
                    overrideReason: overrideReason,
                    idempotencyKey: key
                )
            }
            changeAttemptKey = nil
            changeAppliedOverrides = []
            changeOverrideReason = ""
            pendingMove = nil
            pendingResize = nil
            await load()
        } catch let error as APIError {
            if let prompt = error.bookingOverridePrompt(intent: .edit),
               !changeAppliedOverrides.contains(prompt.flag) {
                changeOverridePrompt = prompt   // keep the pending tile in place
            } else {
                changeError = error.userMessage
                cancelChange()
            }
        } catch {
            changeError = "Couldn’t update your calendar. Please try again."
            cancelChange()
        }
    }
}

/// A calendar change awaiting confirm + submit — a drag-move (new start) or a
/// bottom-edge resize (new duration). Both PATCH /pro/bookings/{id} and share the
/// same override "save it anyway?" retry + idempotency machinery.
private enum PendingCalendarChange {
    case move(PendingCalendarMove)
    case resize(PendingCalendarResize)

    var event: ProCalendarEvent {
        switch self {
        case let .move(move): return move.event
        case let .resize(resize): return resize.event
        }
    }
}

/// The drag-move / resize confirm alert stack, factored out of
/// `ProCalendarView.body` so the (already large) body keeps type-checking quickly:
/// a confirm prompt when a tile is dropped on a new time/length, the override
/// "save it anyway?" retry, and a terminal error. State + actions are injected from
/// the parent; the pending change is derived from whichever optimistic binding the
/// grid set on drop (move or resize).
private struct CalendarChangeAlerts: ViewModifier {
    @Binding var pendingMove: PendingCalendarMove?
    @Binding var pendingResize: PendingCalendarResize?
    @Binding var showChangeConfirm: Bool
    @Binding var changeOverridePrompt: BookingOverridePrompt?
    @Binding var changeOverrideReason: String
    @Binding var changeError: String?
    let title: (PendingCalendarChange) -> String
    let confirmLabel: (PendingCalendarChange) -> String
    let message: (PendingCalendarChange) -> String
    let onConfirm: (PendingCalendarChange) -> Void
    let onOverride: (BookingOverridePrompt) -> Void
    let onCancel: () -> Void

    private var currentChange: PendingCalendarChange? {
        if let move = pendingMove { return .move(move) }
        if let resize = pendingResize { return .resize(resize) }
        return nil
    }

    func body(content: Content) -> some View {
        content
            // A drop set `pendingMove` / `pendingResize`; open the confirm prompt.
            .onChange(of: pendingMove?.id) { if pendingMove != nil { showChangeConfirm = true } }
            .onChange(of: pendingResize?.id) { if pendingResize != nil { showChangeConfirm = true } }
            .alert(
                currentChange.map(title) ?? "Confirm change",
                isPresented: $showChangeConfirm,
                presenting: currentChange
            ) { change in
                Button(confirmLabel(change)) { onConfirm(change) }
                Button("Cancel", role: .cancel) { onCancel() }
            } message: { change in
                Text(message(change))
            }
            .alert(
                "Confirm change",
                isPresented: Binding(
                    get: { changeOverridePrompt != nil },
                    set: { if !$0 { changeOverridePrompt = nil } }
                ),
                presenting: changeOverridePrompt
            ) { prompt in
                TextField(prompt.reasonPlaceholder, text: $changeOverrideReason)
                Button("Save anyway") { onOverride(prompt) }
                Button("Cancel", role: .cancel) { onCancel() }
            } message: { prompt in
                Text(prompt.question)
            }
            .alert(
                "Couldn’t update appointment",
                isPresented: Binding(
                    get: { changeError != nil },
                    set: { if !$0 { changeError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { changeError = nil }
            } message: {
                Text(changeError ?? "")
            }
    }
}
