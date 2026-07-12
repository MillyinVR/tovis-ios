// Day / Week time-grid — the native counterpart of the web `DayWeekGrid`
// (+ `_grid/TimeGutter`, `DayColumn`, `DayHeaderRow`, `EventCard`). A vertical
// 24-hour timeline at `PX_PER_MINUTE` with a time gutter, one column per visible
// day, hour rules, a now-line on today, and event tiles positioned by their
// minutes-since-midnight window (`ProCalendarGrid.eventDayMinutes`). Tapping a
// tile opens the booking detail or the block editor; tapping empty space starts
// a new booking (the FAB also blocks personal time).
//
// Drag-to-reschedule (native port of the web `useDragDrop` + `useConfirmChange`
// move flow): long-press a PENDING/ACCEPTED booking tile to lift it, then drag
// vertically to a new time (snapped to the 15-min grid, clamped within the day).
// On release the parent (`ProCalendarView`) confirms the move and PATCHes
// `/pro/bookings/{id}` via `ProBookingService.reschedule`, reusing the same
// override "save it anyway?" retry as the reschedule form. The long-press arms
// the drag so the enclosing ScrollView doesn't swallow it; a plain tap still
// opens the detail. (Scope: bookings only — blocks stay tap-to-edit — and
// time-only within a day column; cross-day week drag is a follow-up.)
import Combine
import SwiftUI
import TovisKit

/// A booking the pro dropped on a new time, awaiting confirmation. The grid sets
/// it (via a binding) on drop; `ProCalendarView` shows the confirm prompt and,
/// on approval, submits the reschedule. Kept non-nil while a move is pending so
/// the tile renders optimistically at the dropped position until it resolves.
struct PendingCalendarMove: Identifiable {
    let event: ProCalendarEvent
    /// The proposed new start instant (day-local midnight + `newStartMinutes`).
    let newStart: Date
    /// The day column the tile lives in (moves stay within their own day).
    let dayYmd: String
    /// Minutes-since-midnight of the proposed start (drives the optimistic offset).
    let newStartMinutes: Int
    var id: String { event.id }
}

/// Live drag state while a tile is lifted (before release). `currentStartMinutes`
/// is the snapped, clamped minutes-since-midnight the tile currently hovers at.
private struct CalendarDragState: Equatable {
    let eventId: String
    var currentStartMinutes: Int
}

struct ProCalendarTimeGrid: View {
    let view: ProCalendarViewMode          // .day or .week
    let currentDate: Date
    let timeZone: TimeZone
    let events: [ProCalendarEvent]
    let onTapBooking: (String) -> Void
    let onTapBlock: (ProCalendarEvent) -> Void
    /// Tapping empty grid space → start a new booking prefilled to that instant
    /// (the tapped column's day + y-position, snapped to the 15-min step).
    var onTapEmptySlot: ((Date) -> Void)? = nil
    /// Flips when the chrome collapses/expands — re-snaps the timeline to "now"
    /// after the height change.
    var collapseToggle: Bool = false

    /// Set by a drag-drop when a booking is moved to a new time; the parent shows
    /// the confirm prompt + submits the reschedule. Bound so the tile can render
    /// optimistically at the dropped position until the move resolves.
    @Binding var pendingMove: PendingCalendarMove?

    /// Top-most visible hour cell — set to "now" on open (iOS 17 scrollPosition).
    @State private var scrolledHour: Int?

    /// The tile currently lifted under a long-press drag (nil when not dragging).
    @State private var activeDrag: CalendarDragState?

    // Web parity: PX_PER_MINUTE = 1.5 → a 24h day is 2160pt tall.
    private let pxPerMinute: CGFloat = 1.5
    private let stepMinutes = 15
    private let gutterWidth: CGFloat = 52
    private var totalHeight: CGFloat { CGFloat(ProCalendarGrid.minutesPerDay) * pxPerMinute }

    private var days: [ProMonthCell] {
        ProCalendarGrid.timelineDays(
            view: view, reference: currentDate, timeZone: timeZone, today: Date())
    }

    var body: some View {
        // A bounded, internally-scrolling timeline (the day headers stay pinned
        // above it). Opens scrolled to the current hour so a pro lands on "now",
        // while the page above (stats/controls/etc.) stays visible.
        VStack(spacing: 0) {
            headerRow
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        // Real-layout anchor ladder: one cell per hour at its true
                        // height. `scrollPosition(id:)` binds the top-most cell, so
                        // these are the scroll targets (the visual grid uses .offset(),
                        // which can't be targeted directly).
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                Color.clear
                                    .frame(height: CGFloat(60) * pxPerMinute)
                                    .id(hour)
                            }
                        }
                        .scrollTargetLayout()

                        HStack(alignment: .top, spacing: 0) {
                            timeGutter
                            ForEach(days) { day in
                                dayColumn(day)
                                if day.id != days.last?.id {
                                    Rectangle()
                                        .fill(BrandColor.textMuted.opacity(0.12))
                                        .frame(width: 1)
                                }
                            }
                        }
                        .frame(height: totalHeight)
                        // Now-line spans the day columns (inset past the gutter) so in
                        // week view it reads across all seven days, like web. Shown
                        // whenever today is in the visible range; labeled + live-ticking.
                        .overlay(alignment: .topLeading) {
                            if days.contains(where: { $0.isToday }) {
                                ProCalendarNowLine(timeZone: timeZone, pxPerMinute: pxPerMinute)
                                    .padding(.leading, gutterWidth)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    // Trailing room so a midday hour can sit at the very top.
                    Color.clear.frame(height: 640)
                }
            }
            .scrollPosition(id: $scrolledHour, anchor: .top)
            .onAppear { setNowScroll() }
            .onChange(of: scrollKey) { setNowScroll() }
            // Re-snap to "now" once the collapse/expand height change settles.
            .onChange(of: collapseToggle) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { setNowScroll() }
            }
        }
        .background(BrandColor.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(BrandColor.textMuted.opacity(0.12), lineWidth: 1)
        )
    }

    /// Pins the timeline's top to the current hour (or 8am when today isn't in
    /// view), so it opens right under the date header with no empty pre-now gap.
    private func setNowScroll() {
        let todayKey = ProCalendarGrid.ymd(Date(), timeZone)
        let todayVisible = days.contains { $0.dayYmd == todayKey }
        // Open with the hour just before "now" at the top (a little past context),
        // then the current hour and the day ahead below it.
        let nowHour = ProCalendarGrid.minutesSinceMidnight(Date(), timeZone) / 60
        let target = todayVisible ? max(0, nowHour - 1) : 8
        // Defer a tick so the binding applies after the ScrollView's first layout.
        DispatchQueue.main.async { scrolledHour = target }
    }

    /// Changes whenever the visible range changes, so we re-anchor on nav.
    private var scrollKey: String {
        "\(view.rawValue):\(days.first?.dayYmd ?? "")"
    }

    // MARK: - Header (weekday + day number, today highlighted)

    private var headerRow: some View {
        HStack(spacing: 0) {
            // Fixed-width spacer (a bare Color.clear is greedy vertically and would
            // balloon the header's height).
            Spacer().frame(width: gutterWidth)

            if view == .day, let day = days.first {
                // Single day → the full long-form date.
                Text(longDateLabel(day.startOfDay))
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(day.isToday ? BrandColor.accent : BrandColor.textPrimary)
                    .frame(maxWidth: .infinity)
            } else {
                // Week → per-column weekday + day-number (unchanged).
                ForEach(days) { day in
                    VStack(spacing: 1) {
                        Text(weekdayLabel(day.startOfDay))
                            .font(BrandFont.mono(9))
                            .foregroundStyle(BrandColor.textMuted)
                        Text("\(day.dayNumber)")
                            .font(BrandFont.body(13, day.isToday ? .bold : .regular))
                            .foregroundStyle(day.isToday ? BrandColor.onAccent : BrandColor.textPrimary)
                            .frame(width: 22, height: 22)
                            .background(day.isToday ? BrandColor.accent : Color.clear)
                            .clipShape(Circle())
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 6)
        .background(BrandColor.bgSecondary)
    }

    /// Full date for the single-day header, e.g. "Monday, June 29".
    private func longDateLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = timeZone
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: date)
    }

    // MARK: - Time gutter (hour labels)

    private var timeGutter: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: gutterWidth, height: totalHeight)
            ForEach(0..<24) { hour in
                Text(hourLabel(hour))
                    .font(BrandFont.mono(10))
                    .foregroundStyle(BrandColor.textMuted)
                    .frame(width: gutterWidth - 6, alignment: .trailing)
                    // Clamp 12am to the top edge so it doesn't clip off-screen.
                    .offset(y: max(0, CGFloat(hour * 60) * pxPerMinute - 6))
            }
        }
        .frame(width: gutterWidth)
    }

    // MARK: - Day column (hour rules + now-line + event tiles)

    private func dayColumn(_ day: ProMonthCell) -> some View {
        let layouts = events.compactMap { event -> (event: ProCalendarEvent, start: Int, end: Int)? in
            guard let window = ProCalendarGrid.eventDayMinutes(
                startISO: event.startsAt,
                endISO: event.endsAt,
                durationMinutes: event.durationMinutes,
                dayYmd: day.dayYmd,
                timeZone: timeZone,
                stepMinutes: stepMinutes
            ) else { return nil }
            return (event, window.start, window.end)
        }

        // Passive double-book signal: which bookings overlap another booking today.
        let conflictIds = conflictingBookingIds(layouts)

        return ZStack(alignment: .topLeading) {
            // Full-height spacer establishes the ZStack's intrinsic height so the
            // .offset(y:) children measure from the TOP. Without it the ZStack has
            // no intrinsic height and the outer .frame centers everything (the 2×
            // offset bug — a 10am tile landed at ~8:30pm). It also backs the
            // empty-slot tap: event tiles (Buttons) sit on top and take their own
            // taps, so this only fires for genuinely empty space.
            Color.clear
                .frame(maxWidth: .infinity, minHeight: totalHeight, maxHeight: totalHeight)
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        if let date = emptySlotDate(day: day, y: value.location.y) {
                            onTapEmptySlot?(date)
                        }
                    }
                )

            // Hour rules (decorative — let taps fall through to the slot layer).
            ForEach(0..<24) { hour in
                Rectangle()
                    .fill(BrandColor.textMuted.opacity(0.16))
                    .frame(height: 1)
                    .offset(y: CGFloat(hour * 60) * pxPerMinute)
            }
            .allowsHitTesting(false)

            // Event tiles. (The now-line is drawn once across the whole grid as an
            // overlay on the day-columns HStack — see `body` — so in week view it
            // reads as a single line spanning all seven days, matching web.)
            ForEach(layouts, id: \.event.id) { item in
                eventTile(item.event, day: day, startMinutes: item.start, endMinutes: item.end,
                          conflict: conflictIds.contains(item.event.id))
            }
        }
        .background(day.isToday ? BrandColor.accent.opacity(0.04) : Color.clear)
    }

    /// Booking ids on a day whose time window overlaps another booking's — the
    /// passive double-book signal. Blocks are excluded (the pro's own time isn't a
    /// client conflict); uses the laid-out [start, end) minutes, matching what's
    /// drawn. The server still allows the overlap; this only surfaces it.
    private func conflictingBookingIds(
        _ layouts: [(event: ProCalendarEvent, start: Int, end: Int)]
    ) -> Set<String> {
        ProCalendarGrid.overlappingIntervalIds(
            layouts
                .filter { $0.event.isBooking }
                .map { (id: $0.event.id, start: $0.start, end: $0.end) })
    }

    /// Maps a tap's y-position in a day column to the instant it represents:
    /// y → minutes-since-midnight (floored to the 15-min step), added to the
    /// column's local midnight in the calendar timezone. Nil for an out-of-range
    /// tap (below midnight / past the day's end).
    private func emptySlotDate(day: ProMonthCell, y: CGFloat) -> Date? {
        let raw = Int(y / pxPerMinute)
        guard raw >= 0, raw < ProCalendarGrid.minutesPerDay else { return nil }
        let snapped = min((raw / stepMinutes) * stepMinutes,
                          ProCalendarGrid.minutesPerDay - stepMinutes)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(byAdding: .minute, value: snapped, to: day.startOfDay)
    }

    @ViewBuilder
    private func eventTile(
        _ event: ProCalendarEvent, day: ProMonthCell, startMinutes: Int, endMinutes: Int,
        conflict: Bool
    ) -> some View {
        let tone = event.isBlock ? BrandColor.textMuted : statusTone(event.status)
        let duration = max(stepMinutes, endMinutes - startMinutes)
        let draggable = event.isBooking && isReschedulable(event.status)

        let isActive = activeDrag?.eventId == event.id
        let isPending = pendingMove?.event.id == event.id && pendingMove?.dayYmd == day.dayYmd
        // While lifting/dragging (or awaiting confirm) the tile renders at its
        // proposed minutes; otherwise at its real laid-out start.
        let effectiveStart: Int = {
            if let drag = activeDrag, drag.eventId == event.id { return drag.currentStartMinutes }
            if isPending, let move = pendingMove { return move.newStartMinutes }
            return startMinutes
        }()
        let heightPx = CGFloat(duration) * pxPerMinute
        let topPx = CGFloat(effectiveStart) * pxPerMinute
        let micro = heightPx < 28
        let showProposedTime = isActive || isPending

        let tile = tileBody(
            event: event,
            tone: tone,
            micro: micro,
            heightPx: heightPx,
            timeText: showProposedTime ? minutesLabel(effectiveStart) : timeLabel(event.startsAt),
            lifted: isActive,
            pending: isPending,
            conflict: conflict
        )
        .padding(.horizontal, 2)
        .offset(y: topPx)
        .zIndex(isActive ? 2 : (isPending ? 1 : 0))
        .contentShape(Rectangle())
        .onTapGesture {
            if event.isBooking { onTapBooking(event.id) } else { onTapBlock(event) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tileAccessibilityLabel(event, conflict: conflict))
        .accessibilityAddTraits(.isButton)
        .animation(.easeOut(duration: 0.16), value: isPending)

        // A long-press arms the drag (so the ScrollView doesn't steal it), then a
        // vertical drag moves the time. Attached only to reschedulable bookings so
        // blocks / terminal bookings keep a plain tap and don't block scrolling.
        if draggable {
            tile.gesture(
                moveGesture(event: event, day: day, startMinutes: startMinutes, durationMinutes: duration)
            )
        } else {
            tile
        }
    }

    /// The tile's visual body (shared by draggable + static tiles). `lifted` adds a
    /// shadow/scale while dragging; `pending` outlines a dropped-but-unconfirmed move;
    /// `conflict` is the passive double-book signal (amber ring + corner glyph).
    private func tileBody(
        event: ProCalendarEvent,
        tone: Color,
        micro: Bool,
        heightPx: CGFloat,
        timeText: String,
        lifted: Bool,
        pending: Bool,
        conflict: Bool
    ) -> some View {
        // Drag states own the ring; otherwise a conflict paints it amber.
        let ringColor: Color = (lifted || pending)
            ? BrandColor.accent
            : (conflict ? BrandColor.amber : .clear)
        let ringWidth: CGFloat = (lifted || pending) ? 1.5 : (conflict ? 1 : 0)

        return HStack(spacing: 0) {
            Rectangle().fill(tone).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.isBlock ? (event.title.isEmpty ? "Blocked" : event.title) : event.clientName)
                    .font(BrandFont.body(micro ? 10 : 12, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1)
                if !micro {
                    Text(timeText)
                        .font(BrandFont.mono(9))
                        .foregroundStyle(lifted ? BrandColor.accent : BrandColor.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 6)
            .padding(.vertical, 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: max(heightPx - 2, 16), alignment: .top)
        .background(tone.opacity(lifted ? 0.26 : 0.16))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(ringColor, lineWidth: ringWidth)
        )
        // A small amber glyph marks a double-booked tile (hidden while it's the one
        // being dragged, so the drag ring reads cleanly).
        .overlay(alignment: .topTrailing) {
            if conflict && !lifted {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(BrandColor.amber)
                    .padding(3)
            }
        }
        .shadow(color: lifted ? BrandColor.accent.opacity(0.35) : .clear,
                radius: lifted ? 8 : 0, y: lifted ? 3 : 0)
        .scaleEffect(lifted ? 1.02 : 1.0)
        .opacity(lifted ? 0.97 : 1.0)
        .animation(.easeOut(duration: 0.12), value: lifted)
    }

    // MARK: - Drag-to-reschedule

    /// Long-press (arms past the ScrollView) → vertical drag → drop. Translates the
    /// drag's y into minutes at `pxPerMinute`, snaps to the 15-min grid, and clamps
    /// so the tile stays within the day. On drop it hands the parent a `pendingMove`.
    private func moveGesture(
        event: ProCalendarEvent, day: ProMonthCell, startMinutes: Int, durationMinutes: Int
    ) -> some Gesture {
        // Global coordinate space: the tile moves itself via `.offset(y:)` while
        // dragging, so a `.local` space would feed its own movement back into the
        // translation. Global measures a clean finger delta regardless of offset.
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                switch value {
                case .first(true):
                    // Long-press engaged — lift the tile at its current time.
                    activeDrag = CalendarDragState(eventId: event.id, currentStartMinutes: startMinutes)
                case let .second(true, drag):
                    activeDrag = CalendarDragState(
                        eventId: event.id,
                        currentStartMinutes: droppedStartMinutes(
                            from: startMinutes, drag: drag, duration: durationMinutes))
                default:
                    break
                }
            }
            .onEnded { value in
                guard case let .second(_, drag) = value else { activeDrag = nil; return }
                let snapped = droppedStartMinutes(
                    from: startMinutes, drag: drag, duration: durationMinutes)
                activeDrag = nil
                // No net change (or an un-representable instant) → nothing to confirm.
                guard snapped != startMinutes, let newStart = slotDate(day: day, minutes: snapped) else { return }
                pendingMove = PendingCalendarMove(
                    event: event, newStart: newStart, dayYmd: day.dayYmd, newStartMinutes: snapped)
            }
    }

    /// The snapped, clamped minutes-since-midnight a drag drops on (pure math in
    /// `ProCalendarGrid.draggedStartMinutes`, so it's unit-tested there).
    private func droppedStartMinutes(
        from startMinutes: Int, drag: DragGesture.Value?, duration: Int
    ) -> Int {
        ProCalendarGrid.draggedStartMinutes(
            originalStartMinutes: startMinutes,
            translationPoints: Double(drag?.translation.height ?? 0),
            pxPerMinute: Double(pxPerMinute),
            durationMinutes: duration,
            stepMinutes: stepMinutes)
    }

    /// The instant `minutes` past `day`'s local midnight (TZ-aware — same
    /// construction as the empty-slot tap).
    private func slotDate(day: ProMonthCell, minutes: Int) -> Date? {
        ProCalendarGrid.instant(dayStart: day.startOfDay, minutes: minutes, timeZone: timeZone)
    }

    /// Only PENDING / ACCEPTED bookings can be dragged (mirrors the reschedule
    /// action's eligibility — not started, not terminal). The server is the final
    /// authority; this just keeps un-movable tiles tap-only.
    private func isReschedulable(_ status: String) -> Bool {
        switch status.uppercased() {
        case "PENDING", "ACCEPTED": return true
        default: return false
        }
    }

    /// `h:mmam/pm` for a minutes-since-midnight value (the live drag/pending label).
    private func minutesLabel(_ minutes: Int) -> String {
        ProCalendarGrid.minuteOfDayLabel(minutes)
    }

    private func tileAccessibilityLabel(_ event: ProCalendarEvent, conflict: Bool) -> String {
        let name = event.isBlock
            ? (event.title.isEmpty ? "Blocked time" : event.title)
            : event.clientName
        let base = "\(name), \(timeLabel(event.startsAt))"
        return conflict ? "\(base), overlaps another appointment" : base
    }

    // MARK: - Formatting

    private func weekdayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = timeZone
        f.dateFormat = "EEE"
        return f.string(from: date).uppercased()
    }

    private func hourLabel(_ hour: Int) -> String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return "\(h12)\(hour < 12 ? "am" : "pm")"
    }

    private func timeLabel(_ iso: String) -> String {
        Wire.dateTime(iso, timeZone: timeZone.identifier)
            .components(separatedBy: " · ").last ?? ""
    }
}

// MARK: - Now-line

/// The live "current time" indicator — the native counterpart of the web
/// `NowLineOverlay`: an accent-colored rule with a leading dot, a soft glow, and a
/// `NOW · h:mm` pill at the trailing edge. Rendered once as an overlay spanning the
/// day columns, so in week view it reads as a single line across all seven days.
/// It owns its own clock tick so it advances without a calendar reload, and
/// re-renders in isolation (only this subview, not the whole grid).
private struct ProCalendarNowLine: View {
    let timeZone: TimeZone
    let pxPerMinute: CGFloat

    @State private var now = Date()
    // Match web's `NOW_REFRESH_INTERVAL_MS` (30s) so both platforms tick alike.
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        let minutes = ProCalendarGrid.minutesSinceMidnight(now, timeZone)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(BrandColor.accent)
                .frame(height: 2)
                .shadow(color: BrandColor.accent.opacity(0.55), radius: 5)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(BrandColor.accent)
                        .frame(width: 7, height: 7)
                        .shadow(color: BrandColor.accent.opacity(0.7), radius: 4)
                        .offset(x: -1)
                }

            Text("NOW · \(nowLabel(minutes))")
                .font(BrandFont.mono(9))
                .tracking(0.8)
                .foregroundStyle(BrandColor.onAccent)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(BrandColor.accent)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 4)
                .offset(y: -16)
        }
        .offset(y: CGFloat(minutes) * pxPerMinute)
        .onReceive(tick) { now = $0 }
    }

    /// 12-hour `h:mmam/pm` (mirrors the web `formatNowLabel`).
    private func nowLabel(_ totalMinutes: Int) -> String {
        let h24 = (totalMinutes / 60) % 24
        let m = totalMinutes % 60
        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        return "\(h12):\(String(format: "%02d", m))\(h24 < 12 ? "am" : "pm")"
    }
}
