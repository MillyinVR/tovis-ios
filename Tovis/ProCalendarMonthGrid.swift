// Calendar view-switcher controls + month grid — the native counterpart of the
// web `MobileCalendarControls` + `MobileMonthGrid`. The controls expose the
// Day/Week/Month toggle (web `VIEW_ORDER = ['day','week','month']`) with
// prev / Today / next and the range label; the grid is a 6×7 month (Monday-start)
// with per-day event dots. Tapping a day switches to that day's agenda.
import SwiftUI
import TovisKit

// MARK: - Controls (view switcher + range nav)

struct ProCalendarControls: View {
    @Binding var view: ProCalendarViewMode
    let headerLabel: String
    let onPrev: () -> Void
    let onToday: () -> Void
    let onNext: () -> Void

    // Web copy: header.viewLabels (Day / Week / Month), actions.today.
    private let order: [ProCalendarViewMode] = [.day, .week, .month]
    private func label(_ mode: ProCalendarViewMode) -> String {
        switch mode {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            // Segmented view tabs.
            HStack(spacing: 4) {
                ForEach(order, id: \.self) { mode in
                    let active = mode == view
                    Button {
                        if !active {
                            withAnimation(.easeOut(duration: 0.15)) { view = mode }
                        }
                    } label: {
                        Text(label(mode))
                            .font(BrandFont.body(14, active ? .semibold : .regular))
                            .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(active ? BrandColor.accent : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Prev · Today (label = range) · Next. Just tall enough for the date.
            HStack(spacing: 8) {
                navButton(system: "chevron.left", label: "Previous calendar range", action: onPrev)

                Button(action: onToday) {
                    Text(headerLabel)
                        .font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(BrandColor.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                navButton(system: "chevron.right", label: "Next calendar range", action: onNext)
            }
        }
    }

    private func navButton(system: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .frame(width: 34, height: 28)
                .background(BrandColor.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Month grid

/// What a month cell shows beneath its day number, independent of WHERE the
/// day's occupancy came from. The calendar screen maps real `ProCalendarEvent`s;
/// the aftercare rebook sheet maps `/pro/availability/busy-days` counts (which
/// carry no status). One renderer, two feeds — so the two month grids can never
/// drift apart visually.
struct ProMonthDayMarks: Equatable {
    /// One dot per item, in render order (the cell caps how many it draws).
    var dots: [Dot] = []
    /// The pro's weekly schedule disables this weekday. Shaded — and still
    /// TAPPABLE: a pro may deliberately book a client on a day their public
    /// calendar shows as off (the save asks them to confirm the override).
    var isOffDay = false

    /// A booking's status tone, or the pro's own blocked time. `.busy` is a
    /// booking whose status the feed didn't carry (busy-days sends counts).
    enum Dot: Equatable {
        case booking(status: String)
        case busy
        case block
    }
}

struct ProCalendarMonthGrid: View {
    let cells: [ProMonthCell]
    /// Per-day marks keyed to each cell's `dayYmd`. A missing key is a free day.
    let marksByDay: [String: ProMonthDayMarks]
    /// The day currently picked, outlined in the accent. nil = no selection
    /// (the calendar screen, which navigates rather than selects).
    var selectedYmd: String? = nil
    /// Days before this "yyyy-MM-dd" are dimmed and untappable. nil = all days
    /// tappable.
    var minYmd: String? = nil
    let onPickDay: (ProMonthCell) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
    private let weekdayInitials = ["M", "T", "W", "T", "F", "S", "S"] // Monday-start

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Array(weekdayInitials.enumerated()), id: \.offset) { _, initial in
                    Text(initial)
                        .font(BrandFont.mono(11))
                        .foregroundStyle(BrandColor.textMuted)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(cells) { cell in
                    MonthDayCell(
                        cell: cell,
                        marks: marksByDay[cell.dayYmd] ?? ProMonthDayMarks(),
                        isSelected: selectedYmd == cell.dayYmd,
                        // String compare is safe on zero-padded "yyyy-MM-dd".
                        isPast: minYmd.map { cell.dayYmd < $0 } ?? false,
                        onTap: { onPickDay(cell) }
                    )
                }
            }

            HStack(spacing: 14) {
                Text("Today")
                Text("Bookings")
                Spacer()
            }
            .font(BrandFont.mono(10))
            .tracking(0.6)
            .foregroundStyle(BrandColor.textMuted)
            .padding(.top, 2)
        }
    }
}

private struct MonthDayCell: View {
    let cell: ProMonthCell
    let marks: ProMonthDayMarks
    var isSelected = false
    var isPast = false
    let onTap: () -> Void

    private let maxDots = 4

    private func dotTone(_ dot: ProMonthDayMarks.Dot) -> Color {
        switch dot {
        case .block: return BrandColor.textMuted
        case .busy: return BrandColor.accent
        case let .booking(status): return statusTone(status)
        }
    }

    private var dayNumberTone: Color {
        if cell.isToday { return BrandColor.onAccent }
        if isPast { return BrandColor.textMuted.opacity(0.5) }
        guard cell.isInCurrentMonth else { return BrandColor.textMuted }
        // Off days read as "closed, but yours to book" — web shades them
        // textSecondary behind a dashed edge.
        return marks.isOffDay ? BrandColor.textSecondary : BrandColor.textPrimary
    }

    private var borderTone: Color {
        if isSelected { return BrandColor.accent }
        if !marks.dots.isEmpty { return BrandColor.accent.opacity(0.18) }
        // An off day with NOTHING on it still needs a visible edge, or the
        // dash below is drawn in `.clear` and the pro's closed days look
        // identical to their open ones — which is the whole feature.
        // (Caught on the simulator: Sundays rendered blank.)
        return marks.isOffDay ? BrandColor.textMuted.opacity(0.55) : Color.clear
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                Text("\(cell.dayNumber)")
                    .font(BrandFont.body(13, cell.isToday ? .bold : .regular))
                    .foregroundStyle(dayNumberTone)
                    .frame(width: 26, height: 26)
                    .background(cell.isToday ? BrandColor.accent : Color.clear)
                    .clipShape(Circle())

                HStack(spacing: 3) {
                    let visible = marks.dots.prefix(maxDots)
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, dot in
                        Circle()
                            .fill(dotTone(dot))
                            .frame(width: 5, height: 5)
                    }
                    if marks.dots.count > maxDots {
                        Text("+")
                            .font(BrandFont.mono(9))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(cell.isInCurrentMonth ? BrandColor.bgSurface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        borderTone,
                        style: StrokeStyle(
                            lineWidth: isSelected ? 2 : 1,
                            // Dashed = an off day the pro can still book, the
                            // same signal web's popup uses.
                            dash: marks.isOffDay && !isSelected ? [3, 3] : []
                        )
                    )
            )
            .opacity(isPast ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isPast)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let count = marks.dots.count
        var label = "\(cell.dayYmd), \(count) calendar item\(count == 1 ? "" : "s")"
        if marks.isOffDay { label += ", off day" }
        if isSelected { label += ", selected" }
        return label
    }
}
