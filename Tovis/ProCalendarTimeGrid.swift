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
// opens the detail. In week view a drag can also land in a DIFFERENT day column
// (x-hit-testing the captured column frames), moving the event across days at the
// same dropped time. Blocks (the pro's own time) drag too — move + resize route to
// PATCH /pro/calendar/blocked (a different endpoint), branched in the parent.
import Combine
import SwiftUI
import TovisKit
import UIKit

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

/// A booking whose BOTTOM edge the pro dragged to a new duration, awaiting
/// confirmation. The grid sets it (via a binding) on drop; `ProCalendarView` shows
/// the confirm prompt and, on approval, PATCHes the new `durationMinutes`. The
/// start is unchanged — only the length — so the tile keeps its top and renders
/// optimistically at `newDurationMinutes` tall until the change resolves.
struct PendingCalendarResize: Identifiable {
    let event: ProCalendarEvent
    /// The day column the tile lives in (resize stays within its own day).
    let dayYmd: String
    /// The proposed new total duration in minutes (drives the optimistic height).
    let newDurationMinutes: Int
    /// Minutes-since-midnight of the (unchanged) start — the fixed tile top.
    let startMinutes: Int
    var id: String { event.id }
}

/// Live drag state while a tile is lifted (before release). `currentStartMinutes`
/// is the snapped, clamped minutes-since-midnight the tile currently hovers at.
private struct CalendarDragState: Equatable {
    let eventId: String
    var currentStartMinutes: Int
}

/// Live resize state while a tile's bottom edge is being dragged (before release).
/// `currentDurationMinutes` is the snapped, clamped length the tile currently shows.
private struct CalendarResizeState: Equatable {
    let eventId: String
    var currentDurationMinutes: Int
}

/// Collects each day column's global frame (keyed by its `dayYmd`) so a week-view
/// drag can resolve which day column the finger released over (x-hit-testing for
/// cross-day moves). X-extents are scroll-invariant; only vertical scroll shifts.
private struct DayColumnFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Reaches the enclosing `UIScrollView` and turns OFF `delaysContentTouches`, so a
/// long-press on a tile arms **immediately** instead of being swallowed by the
/// scroll view's ~150ms "is this a scroll?" touch-delay — the reason the
/// drag-to-reschedule long-press never armed on device (a quick tap still sailed
/// through on release, but a held press got stuck in the delay). `canCancelContentTouches`
/// stays on, so a real scroll swipe that starts on a tile still scrolls; only the
/// *stationary* hold now registers. Attach to the ScrollView's content via
/// `.background(...)` so the probe lives inside the scroll view's view tree.
private struct ScrollTouchDelayDisabler: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let probe = UIView(frame: .zero)
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            var ancestor = uiView.superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView {
                    scrollView.delaysContentTouches = false
                    return
                }
                ancestor = current.superview
            }
        }
    }
}

/// Drag-to-reschedule haptics, factored out of `ProCalendarTimeGrid.body` (three
/// inline `.sensoryFeedback` closures pushed the body past the type-checker's
/// complexity limit). Fires a firm tap when a tile lifts, a light selection tick
/// on each 15-min snap while dragging, and a solid tap when it drops.
private struct DragHaptics: ViewModifier {
    let liftedId: String?
    let snappedMinutes: Int?
    let droppedId: String?

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(trigger: liftedId) { (old: String?, new: String?) -> SensoryFeedback? in
                (old == nil && new != nil) ? .impact(flexibility: .rigid) : nil
            }
            .sensoryFeedback(trigger: snappedMinutes) { (old: Int?, new: Int?) -> SensoryFeedback? in
                // Both non-nil → an in-drag step change; nil→value is the lift (skip).
                guard let old, let new, old != new else { return nil }
                return .selection
            }
            .sensoryFeedback(trigger: droppedId) { (old: String?, new: String?) -> SensoryFeedback? in
                (new != nil && old != new) ? .impact(flexibility: .solid) : nil
            }
    }
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
    /// The pro's weekly working hours (primary bookable location). When set, each
    /// day column dims the hours outside the working window (web `DayColumn`
    /// off-hours shading). nil until loaded → no shading.
    var workingHours: ProWeekHours? = nil

    /// Set by a drag-drop when a booking is moved to a new time; the parent shows
    /// the confirm prompt + submits the reschedule. Bound so the tile can render
    /// optimistically at the dropped position until the move resolves.
    @Binding var pendingMove: PendingCalendarMove?

    /// Set by a bottom-edge resize when a booking's duration is changed; the parent
    /// confirms + PATCHes the new `durationMinutes`. Bound so the tile can render
    /// optimistically at the dropped height until the resize resolves.
    @Binding var pendingResize: PendingCalendarResize?

    /// Top-most visible hour cell — set to "now" on open (iOS 17 scrollPosition).
    @State private var scrolledHour: Int?

    /// The tile currently lifted under a long-press drag (nil when not dragging).
    @State private var activeDrag: CalendarDragState?

    /// The tile currently being bottom-edge resized (nil when not resizing).
    @State private var activeResize: CalendarResizeState?

    /// Each visible day column's global frame (keyed by `dayYmd`) — drives cross-day
    /// drop resolution in week view (which column the drag released over).
    @State private var dayColumnFrames: [String: CGRect] = [:]

    // Web parity: PX_PER_MINUTE = 1.5 → a 24h day is 2160pt tall.
    private let pxPerMinute: CGFloat = 1.5
    private let stepMinutes = 15
    private let gutterWidth: CGFloat = 52
    private var totalHeight: CGFloat { CGFloat(ProCalendarGrid.minutesPerDay) * pxPerMinute }

    private var days: [ProMonthCell] {
        ProCalendarGrid.timelineDays(
            view: view, reference: currentDate, timeZone: timeZone, today: Date())
    }

    /// The bounded, internally-scrolling 24h timeline (day headers stay pinned
    /// above it). Extracted from `body` so the outer chain stays type-checkable.
    private var timeline: some View {
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
                    // Collect the day columns' global x-extents so a week-view drag
                    // can resolve which column it released over (cross-day move).
                    .onPreferenceChange(DayColumnFramesKey.self) { dayColumnFrames = $0 }
                }
                // Trailing room so a midday hour can sit at the very top.
                Color.clear.frame(height: 640)
            }
            // Turn off the scroll view's content-touch delay so a long-press on a
            // tile arms immediately (otherwise the ~150ms scroll-detection delay
            // swallows the held press and the drag never lifts). Inside the scroll
            // content so the probe can walk up to the UIScrollView.
            .background(ScrollTouchDelayDisabler())
        }
        .scrollPosition(id: $scrolledHour, anchor: .top)
        // While a tile is lifted or being resized, the ScrollView must not pan —
        // otherwise it re-claims the finger's movement mid-gesture and cancels it.
        .scrollDisabled(activeDrag != nil || activeResize != nil)
        .onAppear { setNowScroll() }
        .onChange(of: scrollKey) { setNowScroll() }
        // Re-snap to "now" once the collapse/expand height change settles.
        .onChange(of: collapseToggle) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { setNowScroll() }
        }
    }

    var body: some View {
        // A bounded, internally-scrolling timeline (the day headers stay pinned
        // above it). Opens scrolled to the current hour so a pro lands on "now",
        // while the page above (stats/controls/etc.) stays visible.
        VStack(spacing: 0) {
            headerRow
            timeline
        }
        .background(BrandColor.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(BrandColor.textMuted.opacity(0.12), lineWidth: 1)
        )
        // Drag haptics (extracted to a ViewModifier to keep `body` type-checkable):
        // a firm tap on lift, a light tick on each 15-min snap, a solid tap on drop.
        // Move and resize never overlap, so both feed the same three triggers — a
        // resize lifts/snaps/drops with the identical feedback as a move.
        .modifier(DragHaptics(
            liftedId: activeDrag?.eventId ?? activeResize?.eventId,
            snappedMinutes: activeDrag?.currentStartMinutes ?? activeResize?.currentDurationMinutes,
            droppedId: pendingMove?.id ?? pendingResize?.id
        ))
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

        // Side-by-side column packing over ALL events (bookings AND blocks) so
        // concurrent tiles sit next to each other instead of stacking (the amber
        // conflict ring still marks true double-books on top of the columns).
        let columns = ProCalendarGrid.overlapColumnLayout(
            layouts.map { (id: $0.event.id, start: $0.start, end: $0.end) })

        // Hours outside the pro's working window for this weekday — dimmed behind
        // the grid. Empty until the working-hours load resolves (no shading).
        let offHours: [(start: Int, end: Int)] = workingHours.map {
            ProCalendarGrid.offHoursSegments(week: $0, date: day.startOfDay, timeZone: timeZone)
        } ?? []

        // GeometryReader gives the column's pixel width, which we divide by the
        // per-cluster `columnCount` to size + x-offset each tile.
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Full-height spacer establishes the ZStack's intrinsic height so
                // the .offset(y:) children measure from the TOP. It also backs the
                // empty-slot tap: event tiles sit on top and take their own taps,
                // so this only fires for genuinely empty space.
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

                // Working-hours shading: dim the hours outside the pro's window
                // (drawn behind the rules + tiles; non-interactive so empty-slot
                // taps still fall through to the slot layer below).
                ForEach(Array(offHours.enumerated()), id: \.offset) { _, segment in
                    let segHeight = CGFloat(segment.end - segment.start) * pxPerMinute
                    Rectangle()
                        .fill(BrandColor.textMuted.opacity(0.10))
                        .frame(maxWidth: .infinity, minHeight: segHeight, maxHeight: segHeight)
                        .offset(y: CGFloat(segment.start) * pxPerMinute)
                }
                .allowsHitTesting(false)

                // Hour rules (decorative — let taps fall through to the slot layer).
                ForEach(0..<24) { hour in
                    Rectangle()
                        .fill(BrandColor.textMuted.opacity(0.16))
                        .frame(height: 1)
                        .offset(y: CGFloat(hour * 60) * pxPerMinute)
                }
                .allowsHitTesting(false)

                // Event tiles, each laid into its overlap column. (The now-line is
                // drawn once across the whole grid as an overlay on the day-columns
                // HStack — see `body` — so in week view it spans all seven days.)
                ForEach(layouts, id: \.event.id) { item in
                    let placement = columns[item.event.id]
                    let columnCount = max(1, placement?.columnCount ?? 1)
                    let column = placement?.column ?? 0
                    let colWidth = geo.size.width / CGFloat(columnCount)
                    eventTile(item.event, day: day, startMinutes: item.start, endMinutes: item.end,
                              conflict: conflictIds.contains(item.event.id),
                              colWidth: colWidth, colX: colWidth * CGFloat(column))
                }
            }
            // Publish this column's global x-extent for cross-day drop resolution.
            .preference(key: DayColumnFramesKey.self, value: [day.dayYmd: geo.frame(in: .global)])
        }
        .frame(height: totalHeight)
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
        conflict: Bool, colWidth: CGFloat, colX: CGFloat
    ) -> some View {
        let tone = event.isBlock ? BrandColor.textMuted : statusTone(event.status)
        let duration = max(stepMinutes, endMinutes - startMinutes)
        // Bookings drag only while reschedulable; blocks (the pro's own time) always
        // drag — move + resize route to /pro/calendar/blocked instead of the booking
        // endpoint (branched in ProCalendarView.submitChange).
        let draggable = (event.isBooking && isReschedulable(event.status)) || event.isBlock
        // Gate the resize handle on the tile's LAID-OUT height (not the live one),
        // so it stays mounted through a shrink and never tears down the in-flight
        // gesture; only tall-enough tiles get a bottom grab zone.
        let showResizeHandle = draggable && CGFloat(duration) * pxPerMinute >= 44

        let isActive = activeDrag?.eventId == event.id
        let isPending = pendingMove?.event.id == event.id && pendingMove?.dayYmd == day.dayYmd
        let isResizing = activeResize?.eventId == event.id
        let isPendingResize = pendingResize?.event.id == event.id && pendingResize?.dayYmd == day.dayYmd
        // While lifting/dragging (or awaiting confirm) the tile renders at its
        // proposed minutes; otherwise at its real laid-out start.
        let effectiveStart: Int = {
            if let drag = activeDrag, drag.eventId == event.id { return drag.currentStartMinutes }
            if isPending, let move = pendingMove { return move.newStartMinutes }
            return startMinutes
        }()
        // A resize keeps the start (top) fixed and changes only the height; while
        // resizing (or awaiting confirm) the tile renders at its proposed length.
        let effectiveDuration: Int = {
            if let resize = activeResize, resize.eventId == event.id { return resize.currentDurationMinutes }
            if isPendingResize, let resize = pendingResize { return resize.newDurationMinutes }
            return duration
        }()
        let heightPx = CGFloat(effectiveDuration) * pxPerMinute
        let topPx = CGFloat(effectiveStart) * pxPerMinute
        let micro = heightPx < 28
        let lifted = isActive || isResizing
        let pending = isPending || isPendingResize
        // Moving shows the new start; resizing shows the new END the bottom edge is
        // dragging toward; otherwise the real start time.
        let timeText: String = {
            if isResizing || isPendingResize { return minutesLabel(effectiveStart + effectiveDuration) }
            if isActive || isPending { return minutesLabel(effectiveStart) }
            return timeLabel(event.startsAt)
        }()

        let tile = tileBody(
            event: event,
            tone: tone,
            micro: micro,
            heightPx: heightPx,
            timeText: timeText,
            lifted: lifted,
            pending: pending,
            conflict: conflict
        )
        .padding(.horizontal, 1.5)
        .frame(width: colWidth, alignment: .leading)
        .offset(x: colX, y: topPx)
        .zIndex(lifted ? 2 : (pending ? 1 : 0))
        .contentShape(Rectangle())
        .onTapGesture {
            if event.isBooking { onTapBooking(event.id) } else { onTapBlock(event) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tileAccessibilityLabel(event, conflict: conflict))
        .accessibilityAddTraits(.isButton)
        .animation(.easeOut(duration: 0.16), value: pending)

        // A standalone long-press arms the drag; a gated drag then moves the time.
        // Attached as a SIMULTANEOUS gesture so it recognizes alongside the enclosing
        // ScrollView's pan rather than fighting it for priority (the old sequenced
        // high-priority form never armed on device). A quick tap still opens the
        // detail (the long-press never fires, the gated drag is a no-op); scrolling
        // still works until the tile is armed, at which point `.scrollDisabled` stops
        // the pan. Attached only to draggable events. A bottom-edge resize handle
        // rides on top with its own (shorter) arm-then-drag so the edge resizes.
        if draggable {
            tile
                .simultaneousGesture(
                    moveGesture(event: event, day: day, startMinutes: startMinutes, durationMinutes: duration)
                )
                .overlay(alignment: .bottom) {
                    if showResizeHandle {
                        resizeHandle(event: event, day: day,
                                     startMinutes: startMinutes, durationMinutes: duration)
                    }
                }
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

    /// Decoupled arm-then-drag: a STANDALONE long-press lifts the tile, and a
    /// SEPARATE drag (gated on "armed") repositions it. Both run as
    /// `.simultaneousGesture`s so they recognize ALONGSIDE the enclosing ScrollView's
    /// pan instead of fighting it for priority — the old sequenced
    /// `.highPriorityGesture` form never armed on device (the held press got lost to
    /// the scroll pan). Global space so the tile's own `.offset` while dragging
    /// doesn't feed back into the translation.
    private func moveGesture(
        event: ProCalendarEvent, day: ProMonthCell, startMinutes: Int, durationMinutes: Int
    ) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3, maximumDistance: 30)
            .onEnded { _ in
                // Arm only if nothing else is active (a handle resize wins the edge).
                guard activeDrag == nil, activeResize == nil else { return }
                activeDrag = CalendarDragState(eventId: event.id, currentStartMinutes: startMinutes)
            }
            .simultaneously(with:
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { drag in
                        // Only tracks once the long-press has lifted THIS tile.
                        guard activeDrag?.eventId == event.id else { return }
                        activeDrag = CalendarDragState(
                            eventId: event.id,
                            currentStartMinutes: droppedStartMinutes(
                                from: startMinutes, drag: drag, duration: durationMinutes))
                    }
                    .onEnded { drag in
                        guard activeDrag?.eventId == event.id else { return }
                        let snapped = droppedStartMinutes(
                            from: startMinutes, drag: drag, duration: durationMinutes)
                        // In week view the tile can land in a different day column —
                        // resolve it from the release x; day view keeps one column.
                        let targetDay = dropTargetDay(globalX: drag.location.x, fallback: day)
                        activeDrag = nil
                        let sameDay = targetDay.dayYmd == day.dayYmd
                        // No net change → nothing to confirm.
                        guard !(sameDay && snapped == startMinutes),
                              let newStart = slotDate(day: targetDay, minutes: snapped) else { return }
                        pendingMove = PendingCalendarMove(
                            event: event, newStart: newStart, dayYmd: targetDay.dayYmd, newStartMinutes: snapped)
                    }
            )
    }

    /// The day column a week-view drag released over (x-hit-testing the captured
    /// column frames), or `fallback` when the release is outside all columns / in
    /// day view. The vertical drop time is column-independent, so a cross-day drop
    /// keeps the same time-of-day on the new day.
    private func dropTargetDay(globalX: CGFloat, fallback: ProMonthCell) -> ProMonthCell {
        guard view == .week else { return fallback }
        let columns = days.compactMap { cell -> (key: String, minX: Double, maxX: Double)? in
            guard let frame = dayColumnFrames[cell.dayYmd] else { return nil }
            return (key: cell.dayYmd, minX: Double(frame.minX), maxX: Double(frame.maxX))
        }
        guard let key = ProCalendarGrid.dayColumnForX(Double(globalX), columns: columns),
              let match = days.first(where: { $0.dayYmd == key })
        else { return fallback }
        return match
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

    // MARK: - Resize (bottom-edge drag → new duration)

    /// The bottom-edge grab strip on a draggable tile: a small centered grip inside a
    /// touch-sized clear strip, riding as an overlay ON TOP of the move gesture. It
    /// carries its own arm-then-drag gesture with a slightly SHORTER long-press than
    /// the move, so grabbing the edge arms the resize first and wins over a move. It
    /// brightens to accent while armed. Kept out of the accessibility tree (the tile
    /// itself carries the label).
    private func resizeHandle(
        event: ProCalendarEvent, day: ProMonthCell, startMinutes: Int, durationMinutes: Int
    ) -> some View {
        let armed = activeResize?.eventId == event.id
        return ZStack {
            Color.clear.frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
            Capsule()
                .fill(armed ? BrandColor.accent : BrandColor.textMuted.opacity(0.55))
                .frame(width: 26, height: 4)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 1.5)
        .simultaneousGesture(
            resizeGesture(event: event, day: day,
                          startMinutes: startMinutes, durationMinutes: durationMinutes)
        )
        .accessibilityHidden(true)
    }

    /// Decoupled arm-then-drag for the bottom edge (same simultaneous strategy as the
    /// move gesture). A standalone long-press — a touch SHORTER than the move's, so on
    /// the handle it arms first and wins — sets `activeResize`; a gated drag then
    /// changes the duration (start fixed, snapped to the 15-min grid, clamped within
    /// the day + max length). Global space so the growing tile's own height change
    /// doesn't feed back into the translation. On drop it hands the parent a
    /// `pendingResize`.
    private func resizeGesture(
        event: ProCalendarEvent, day: ProMonthCell, startMinutes: Int, durationMinutes: Int
    ) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25, maximumDistance: 30)
            .onEnded { _ in
                guard activeDrag == nil, activeResize == nil else { return }
                activeResize = CalendarResizeState(
                    eventId: event.id, currentDurationMinutes: durationMinutes)
            }
            .simultaneously(with:
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { drag in
                        guard activeResize?.eventId == event.id else { return }
                        activeResize = CalendarResizeState(
                            eventId: event.id,
                            currentDurationMinutes: resizedDuration(
                                from: startMinutes, original: durationMinutes, drag: drag))
                    }
                    .onEnded { drag in
                        guard activeResize?.eventId == event.id else { return }
                        let newDuration = resizedDuration(
                            from: startMinutes, original: durationMinutes, drag: drag)
                        // Compare against the ZERO-drag result, not the raw laid-out
                        // duration: a tile whose end isn't on the 15-min grid snaps on
                        // release even with no drag, so guarding on `durationMinutes`
                        // would spuriously resize on a bare arm-and-release.
                        let restingDuration = resizedDuration(
                            from: startMinutes, original: durationMinutes, drag: nil)
                        activeResize = nil
                        guard newDuration != restingDuration else { return }
                        pendingResize = PendingCalendarResize(
                            event: event, dayYmd: day.dayYmd,
                            newDurationMinutes: newDuration, startMinutes: startMinutes)
                    }
            )
    }

    /// The snapped, clamped new duration a bottom-edge drag lands on (pure math in
    /// `ProCalendarGrid.resizedDurationMinutes`, so it's unit-tested there).
    private func resizedDuration(
        from startMinutes: Int, original durationMinutes: Int, drag: DragGesture.Value?
    ) -> Int {
        ProCalendarGrid.resizedDurationMinutes(
            originalStartMinutes: startMinutes,
            originalDurationMinutes: durationMinutes,
            translationPoints: Double(drag?.translation.height ?? 0),
            pxPerMinute: Double(pxPerMinute),
            stepMinutes: stepMinutes)
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
