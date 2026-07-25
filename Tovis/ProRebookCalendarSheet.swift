// "My calendar" — a month overlay of the PRO's own commitments, shown beside
// the aftercare rebook picker so they can place the next appointment around
// what they already have. Native counterpart of web's
// `app/pro/bookings/[id]/aftercare/AvailabilityCalendarPopup`: booked-day dots,
// blocked days, off-day shading, and a tap that drives the picker's day.
//
// Data: GET /api/v1/pro/availability/busy-days (`ProCalendarService.busyDays`),
// the SAME endpoint the web popup reads — and the reason it exists. The other
// candidate, `ProCalendarService.calendar`, is LOCATION-SCOPED (its booking
// query filters `locationId: selectedLocation.id`, defaulting to the primary),
// so a pro who works a salon and a mobile base would see a day as free while
// their other location is full. It also ships every event in full — client
// names, ids, times — where this overlay needs (and should see) nothing but a
// count. busy-days is cross-location, service-agnostic, and name-free.
//
// Off days stay TAPPABLE — that is the point of the feature. Days before the
// picker's floor do not, matching the web popup's `earliest`.
import SwiftUI
import TovisKit

struct ProRebookCalendarSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// The zone the days are bucketed in — the appointment's location zone, the
    /// same one the picker's day stepper is pinned to.
    let timeZone: TimeZone
    /// Weekday indexes (0=Sun … 6=Sat) the pro's weekly schedule disables.
    let offWeekdays: Set<Int>
    /// The day currently chosen in the picker, outlined in the grid.
    let selectedDay: Date
    /// Earliest selectable day — today in `timeZone`, matching the picker's
    /// `in: Date()...` floor.
    let earliest: Date
    /// The pro picked a day, as an instant inside it in `timeZone` — never
    /// before `earliest`, because the pickers it drives are floored there
    /// (`in: Date()...`) and would fight a value below their own range. For
    /// today that means "now", for any later day its local midnight.
    let onPick: (Date) -> Void

    @State private var month: Date
    @State private var busy: [String: ProBusyDay] = [:]
    @State private var loading = false

    init(
        timeZone: TimeZone,
        offWeekdays: Set<Int>,
        selectedDay: Date,
        earliest: Date,
        onPick: @escaping (Date) -> Void
    ) {
        self.timeZone = timeZone
        self.offWeekdays = offWeekdays
        self.selectedDay = selectedDay
        self.earliest = earliest
        self.onPick = onPick
        // Open on the month of the current pick (never before the floor's
        // month), anchored at local noon so month stepping is DST-safe.
        let anchor = max(selectedDay, earliest)
        _month = State(initialValue: ProCalendarGrid.anchorNoon(anchor, timeZone: timeZone))
    }

    private var cells: [ProMonthCell] {
        ProCalendarGrid.monthCells(reference: month, timeZone: timeZone, today: Date())
    }

    private var earliestYmd: String { ProCalendarGrid.ymd(earliest, timeZone) }
    private var selectedYmd: String { ProCalendarGrid.ymd(selectedDay, timeZone) }

    /// Can't page back past the floor's month — there is nothing bookable
    /// there. Steps with the SAME function the back button calls, so the guard
    /// and the action can never disagree about where "one month back" lands.
    private var canGoBack: Bool {
        let previous = ProCalendarGrid.step(
            view: .month, reference: month, by: -1, timeZone: timeZone)
        return ProCalendarGrid.ymd(previous, timeZone).prefix(7)
            >= earliestYmd.prefix(7)
    }

    /// One dot per commitment: the day's bookings (status unknown — this feed
    /// sends counts) plus a muted dot when a block touches it, mirroring the
    /// web popup's booked/blocked legend.
    private var marksByDay: [String: ProMonthDayMarks] {
        var marks: [String: ProMonthDayMarks] = [:]
        for cell in cells {
            let day = busy[cell.dayYmd]
            var entry = ProMonthDayMarks()
            entry.dots = Array(repeating: .busy, count: max(0, day?.bookings ?? 0))
            if day?.blocked == true { entry.dots.append(.block) }
            entry.isOffDay = isOffDay(cell)
            if entry != ProMonthDayMarks() { marks[cell.dayYmd] = entry }
        }
        return marks
    }

    private func isOffDay(_ cell: ProMonthCell) -> Bool {
        guard !offWeekdays.isEmpty else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        // Calendar.weekday is 1-based (1 = Sunday).
        return offWeekdays.contains(cal.component(.weekday, from: cell.startOfDay) - 1)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    ProCalendarMonthGrid(
                        cells: cells,
                        marksByDay: marksByDay,
                        selectedYmd: selectedYmd,
                        minYmd: earliestYmd,
                        onPickDay: { cell in
                            onPick(max(cell.startOfDay, earliest))
                            dismiss()
                        }
                    )
                    legend
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("My calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.tint(BrandColor.accent)
                }
            }
        }
        // Re-fetch per displayed month; the grid spans 42 days, so ask for the
        // whole window rather than the calendar month.
        .task(id: ProCalendarGrid.ymd(month, timeZone).prefix(7)) { await loadBusy() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            navButton(system: "chevron.left", label: "Previous month", disabled: !canGoBack) {
                month = ProCalendarGrid.step(
                    view: .month, reference: month, by: -1, timeZone: timeZone)
            }
            VStack(spacing: 2) {
                Text(ProCalendarGrid.headerLabel(
                    view: .month, reference: month, timeZone: timeZone))
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                if loading {
                    Text("Loading…")
                        .font(BrandFont.mono(9)).foregroundStyle(BrandColor.textMuted)
                }
            }
            .frame(maxWidth: .infinity)
            navButton(system: "chevron.right", label: "Next month", disabled: false) {
                month = ProCalendarGrid.step(
                    view: .month, reference: month, by: 1, timeZone: timeZone)
            }
        }
    }

    private func navButton(
        system: String, label: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(disabled ? BrandColor.textMuted : BrandColor.textPrimary)
                .frame(width: 34, height: 28)
                .background(BrandColor.bgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                legendItem(color: BrandColor.accent, label: "Booked")
                legendItem(color: BrandColor.textMuted, label: "Blocked")
                Spacer()
            }
            if !offWeekdays.isEmpty {
                Text("Dashed days are outside your working hours — you can still book them.")
                    .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Times in \(timeZone.identifier).")
                .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(BrandFont.mono(10)).tracking(0.6)
                .foregroundStyle(BrandColor.textMuted)
        }
    }

    private func loadBusy() async {
        guard let first = cells.first, let last = cells.last else { return }
        loading = true
        defer { loading = false }
        do {
            let response = try await session.client.proCalendar.busyDays(
                from: first.dayYmd, to: last.dayYmd, tz: timeZone.identifier)
            busy = response.days
        } catch {
            // The overlay is optional — a failure leaves the grid usable, which
            // is exactly what the web popup does on a non-OK response.
            busy = [:]
        }
    }
}
