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

            // Prev · Today (label = range) · Next.
            HStack(spacing: 10) {
                navButton(system: "chevron.left", label: "Previous calendar range", action: onPrev)

                Button(action: onToday) {
                    Text(headerLabel)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(BrandColor.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                navButton(system: "chevron.right", label: "Next calendar range", action: onNext)
            }
        }
    }

    private func navButton(system: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .frame(width: 42, height: 40)
                .background(BrandColor.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Month grid

struct ProCalendarMonthGrid: View {
    let cells: [ProMonthCell]
    /// Events bucketed by `localDateKey` — keyed to each cell's `dayYmd`.
    let eventsByDay: [String: [ProCalendarEvent]]
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
                        events: eventsByDay[cell.dayYmd] ?? [],
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
    let events: [ProCalendarEvent]
    let onTap: () -> Void

    private let maxDots = 4

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                Text("\(cell.dayNumber)")
                    .font(BrandFont.body(13, cell.isToday ? .bold : .regular))
                    .foregroundStyle(
                        cell.isToday
                            ? BrandColor.onAccent
                            : (cell.isInCurrentMonth ? BrandColor.textPrimary : BrandColor.textMuted)
                    )
                    .frame(width: 26, height: 26)
                    .background(cell.isToday ? BrandColor.accent : Color.clear)
                    .clipShape(Circle())

                HStack(spacing: 3) {
                    let visible = events.prefix(maxDots)
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, event in
                        Circle()
                            .fill(event.isBlock ? BrandColor.textMuted : statusTone(event.status))
                            .frame(width: 5, height: 5)
                    }
                    if events.count > maxDots {
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
                        events.isEmpty ? Color.clear : BrandColor.accent.opacity(0.18),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(cell.dayYmd), \(events.count) calendar item\(events.count == 1 ? "" : "s")")
    }
}
