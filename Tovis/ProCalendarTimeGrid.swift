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
        // The timeline flows in the page's scroll (web mobile "Option A"): a single
        // 24h column at full height, NOT an inner ScrollView — nesting a second
        // vertical scroller inside the page broke the gutter/header layout.
        VStack(spacing: 0) {
            headerRow
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
        .background(BrandColor.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(BrandColor.textMuted.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Header (weekday + day number, today highlighted)

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutterWidth)
            ForEach(days) { day in
                VStack(spacing: 2) {
                    Text(weekdayLabel(day.startOfDay))
                        .font(BrandFont.mono(10))
                        .foregroundStyle(BrandColor.textMuted)
                    Text("\(day.dayNumber)")
                        .font(BrandFont.body(15, day.isToday ? .bold : .regular))
                        .foregroundStyle(day.isToday ? BrandColor.onAccent : BrandColor.textPrimary)
                        .frame(width: 26, height: 26)
                        .background(day.isToday ? BrandColor.accent : Color.clear)
                        .clipShape(Circle())
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
        .background(BrandColor.bgSecondary)
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
