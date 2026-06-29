// Day / Week time-grid — the native counterpart of the web `DayWeekGrid`
// (+ `_grid/TimeGutter`, `DayColumn`, `DayHeaderRow`, `EventCard`). A vertical
// 24-hour timeline at `PX_PER_MINUTE` with a time gutter, one column per visible
// day, hour rules, a now-line on today, and event tiles positioned by their
// minutes-since-midnight window (`ProCalendarGrid.eventDayMinutes`). Tapping a
// tile opens the booking detail or the block editor. Read-only: block creation
// is the FAB, booking edits live in the detail screen (web drag/resize omitted).
import SwiftUI
import TovisKit

struct ProCalendarTimeGrid: View {
    let view: ProCalendarViewMode          // .day or .week
    let currentDate: Date
    let timeZone: TimeZone
    let events: [ProCalendarEvent]
    let onTapBooking: (String) -> Void
    let onTapBlock: (ProCalendarEvent) -> Void

    /// Top-most visible hour cell — set to "now" on open (iOS 17 scrollPosition).
    @State private var scrolledHour: Int?

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
                    }
                    // Trailing room so a midday hour can sit at the very top.
                    Color.clear.frame(height: 640)
                }
            }
            .scrollPosition(id: $scrolledHour, anchor: .top)
            .onAppear { setNowScroll() }
            .onChange(of: scrollKey) { setNowScroll() }
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

        return ZStack(alignment: .topLeading) {
            // Full-height spacer establishes the ZStack's intrinsic height so the
            // .offset(y:) children measure from the TOP. Without it the ZStack has
            // no intrinsic height and the outer .frame centers everything (the 2×
            // offset bug — a 10am tile landed at ~8:30pm).
            Color.clear.frame(maxWidth: .infinity, minHeight: totalHeight, maxHeight: totalHeight)

            // Hour rules.
            ForEach(0..<24) { hour in
                Rectangle()
                    .fill(BrandColor.textMuted.opacity(0.16))
                    .frame(height: 1)
                    .offset(y: CGFloat(hour * 60) * pxPerMinute)
            }

            // Event tiles.
            ForEach(layouts, id: \.event.id) { item in
                eventTile(item.event,
                          topPx: CGFloat(item.start) * pxPerMinute,
                          heightPx: CGFloat(item.end - item.start) * pxPerMinute)
            }

            // Now-line (today only).
            if day.isToday {
                nowLine
            }
        }
        .background(day.isToday ? BrandColor.accent.opacity(0.04) : Color.clear)
    }

    private var nowLine: some View {
        let minutes = ProCalendarGrid.minutesSinceMidnight(Date(), timeZone)
        return Rectangle()
            .fill(BrandColor.ember)
            .frame(height: 2)
            .overlay(alignment: .leading) {
                Circle().fill(BrandColor.ember).frame(width: 7, height: 7).offset(x: -1)
            }
            .offset(y: CGFloat(minutes) * pxPerMinute)
    }

    private func eventTile(_ event: ProCalendarEvent, topPx: CGFloat, heightPx: CGFloat) -> some View {
        let tone = event.isBlock ? BrandColor.textMuted : statusTone(event.status)
        let micro = heightPx < 28
        return Button {
            if event.isBooking { onTapBooking(event.id) } else { onTapBlock(event) }
        } label: {
            HStack(spacing: 0) {
                Rectangle().fill(tone).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.isBlock ? (event.title.isEmpty ? "Blocked" : event.title) : event.clientName)
                        .font(BrandFont.body(micro ? 10 : 12, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    if !micro {
                        Text(timeLabel(event.startsAt))
                            .font(BrandFont.mono(9))
                            .foregroundStyle(BrandColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 6)
                .padding(.vertical, 2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: max(heightPx - 2, 16), alignment: .top)
            .background(tone.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
        .offset(y: topPx)
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
