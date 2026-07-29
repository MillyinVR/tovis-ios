// "My calendar" — a month view of the PRO's own commitments that IS the
// aftercare rebook picker (R2), not a secondary affordance behind a button.
// Native counterpart of web's
// `app/pro/bookings/[id]/aftercare/AvailabilityCalendarPopup`: booked-day dots,
// blocked days, off-day shading, skip-ahead chips, and a tap that drives the
// picker's day.
//
// Two shapes, one body — mirroring web's `variant` prop:
//  - `ProRebookCalendarView` (inline): always visible, the selection stays put.
//    Booked mode's day picker and window mode's START picker.
//  - `ProRebookCalendarSheet` (modal): the original sheet; picking also closes
//    it. Kept for the window END field, whose own row owns the value.
//
// The skip-ahead chips (+1w / +2w / +4w / Suggested) step the SELECTION forward
// from the selected day — tapping "+1w" repeatedly skips ahead a week at a time
// — and the month view follows. There is deliberately NO separate week pager:
// on a month-aligned grid a "week" view has nothing to page (web R1 dropped it
// for the same reason); the chips ARE the week stepping.
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

struct ProRebookCalendarView: View {
    @Environment(SessionModel.self) private var session

    /// The zone the days are bucketed in — the appointment's location zone, the
    /// same one the picker's day stepper is pinned to.
    let timeZone: TimeZone
    /// Weekday indexes (0=Sun … 6=Sat) the pro's weekly schedule disables.
    let offWeekdays: Set<Int>
    /// The day currently chosen in the picker, outlined in the grid — and the
    /// day the skip-ahead chips step FORWARD from.
    let selectedDay: Date
    /// Earliest selectable day — today in `timeZone` for a booked appointment,
    /// tomorrow for a recommended window (whose save refuses today).
    let earliest: Date
    /// The offering's suggested rebook day (service date + its usual rebook
    /// interval). `nil`, or a day already past `earliest`, hides the chip.
    var suggestedDay: Date? = nil
    /// The pro picked a day, as an instant inside it in `timeZone` — never
    /// before `earliest`, because the pickers it drives are floored there
    /// (`in: Date()...`) and would fight a value below their own range. For
    /// today that means "now", for any later day its local midnight.
    let onPick: (Date) -> Void
    /// What to count OPEN slots for (R4). `nil` keeps the original busy-only
    /// overlay, so a surface that doesn't know the service yet degrades instead
    /// of breaking.
    var slotContext: ProBusyDaysSlotContext? = nil

    @State private var month: Date
    @State private var busy: [String: ProBusyDay] = [:]
    /// Whether the response actually CARRIED counts. Asking for them is not the
    /// same as getting them (an unbookable service/location resolves to none),
    /// and a day must never render as "0 open" when it was simply never counted.
    @State private var openSlotsComputed = false
    @State private var loading = false

    /// Ceiling on synthesized dots per day. Comfortably above the cell's own
    /// 4-dot cap, so "5 bookings" and "500" render identically ("+"), while a
    /// nonsense count off the wire can't turn into a nonsense allocation.
    private static let maxRenderedDots = 24

    /// Skip-ahead steps, in WEEKS — the same set web R1 shipped (+1w/+2w/+4w).
    private static let jumpChips: [(weeks: Int, label: String, hint: String)] = [
        (1, "+1w", "Skip ahead 1 week"),
        (2, "+2w", "Skip ahead 2 weeks"),
        (4, "+4w", "Skip ahead 4 weeks"),
    ]

    init(
        timeZone: TimeZone,
        offWeekdays: Set<Int>,
        selectedDay: Date,
        earliest: Date,
        suggestedDay: Date? = nil,
        onPick: @escaping (Date) -> Void,
        slotContext: ProBusyDaysSlotContext? = nil
    ) {
        self.timeZone = timeZone
        self.offWeekdays = offWeekdays
        self.selectedDay = selectedDay
        self.earliest = earliest
        self.suggestedDay = suggestedDay
        self.onPick = onPick
        self.slotContext = slotContext
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

    /// The suggested day, only while it's still selectable — a rebook interval
    /// that lands in the past (an old booking being corrected) offers nothing.
    private var selectableSuggestedDay: Date? {
        guard let suggestedDay else { return nil }
        guard ProCalendarGrid.ymd(suggestedDay, timeZone) >= earliestYmd else { return nil }
        return suggestedDay
    }

    /// One dot per commitment: the day's bookings (status unknown — this feed
    /// sends counts) plus a muted dot when a block touches it, mirroring the
    /// web popup's booked/blocked legend.
    private var marksByDay: [String: ProMonthDayMarks] {
        var marks: [String: ProMonthDayMarks] = [:]
        for cell in cells {
            let day = busy[cell.dayYmd]
            var entry = ProMonthDayMarks()
            // Clamped: the cell draws 4 dots and a "+" for anything beyond, so a
            // decoded count only has to survive the comparison — never allocate
            // per booking on a number the wire supplied.
            let bookings = min(max(0, day?.bookings ?? 0), Self.maxRenderedDots)
            entry.dots = Array(repeating: .busy, count: bookings)
            if day?.blocked == true { entry.dots.append(.block) }
            entry.isOffDay = isOffDay(cell)
            // Only when the server SAID it counted. A past day is left uncounted
            // too: the grid dims those anyway, and "0 open" on yesterday reads
            // as a refusal rather than as history.
            if openSlotsComputed, cell.dayYmd >= earliestYmd {
                entry.openSlots = max(0, day?.openSlots ?? 0)
            }
            if entry != ProMonthDayMarks() { marks[cell.dayYmd] = entry }
        }
        return marks
    }

    /// Month + service context, as one stable string. A new `slotContext` value
    /// with identical contents must NOT retrigger the fetch, which is why this
    /// is composed from its fields rather than from object identity.
    private var fetchKey: String {
        let ctx = slotContext
        return [
            String(ProCalendarGrid.ymd(month, timeZone).prefix(7)),
            ctx?.serviceId ?? "",
            ctx?.locationType ?? "",
            ctx?.locationId ?? "",
            ctx?.addOnIds.joined(separator: ",") ?? "",
            ctx?.rescheduleBookingId ?? "",
        ].joined(separator: "|")
    }

    private func isOffDay(_ cell: ProMonthCell) -> Bool {
        guard !offWeekdays.isEmpty else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        // Calendar.weekday is 1-based (1 = Sunday).
        return offWeekdays.contains(cal.component(.weekday, from: cell.startOfDay) - 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            skipAhead
            ProCalendarMonthGrid(
                cells: cells,
                marksByDay: marksByDay,
                selectedYmd: selectedYmd,
                minYmd: earliestYmd,
                onPickDay: { pick($0.startOfDay) }
            )
            legend
        }
        // Re-fetch per displayed month; the grid spans 42 days, so ask for the
        // whole window rather than the calendar month. The slot context is part
        // of the id because changing the service or location changes the COUNTS,
        // not just the month.
        .task(id: fetchKey) { await loadBusy() }
        // Follow the selection: a chip jump — or the compact date picker below
        // the grid — moves the month into view. Paging ‹/› by hand never snaps
        // back, because only a CHANGED selection runs this.
        .onChange(of: selectedYmd) { _, _ in
            month = ProCalendarGrid.anchorNoon(max(selectedDay, earliest), timeZone: timeZone)
        }
    }

    /// Hand a picked day up, never below the floor — the pickers it drives are
    /// themselves floored at `earliest` and would fight a lower value.
    private func pick(_ day: Date) {
        onPick(max(day, earliest))
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

    /// Skip ahead a week at a time from the DAY THAT IS SELECTED (Tori's ask) —
    /// tap +1w four times and you have stepped a month, one week per tap, with
    /// the month view following each step.
    private var skipAhead: some View {
        HStack(spacing: 6) {
            Text("SKIP AHEAD")
                .font(BrandFont.mono(9)).tracking(0.8)
                .foregroundStyle(BrandColor.textMuted)
            ForEach(Self.jumpChips, id: \.weeks) { chip in
                Button {
                    // Week stepping via the calendar's own step function, so a
                    // chip can never disagree with the grid about where a week
                    // lands (DST-safe: it re-anchors to local noon).
                    pick(ProCalendarGrid.step(
                        view: .week,
                        reference: max(selectedDay, earliest),
                        by: chip.weeks,
                        timeZone: timeZone,
                    ))
                } label: {
                    chipLabel(chip.label)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chip.hint)
            }
            if let suggested = selectableSuggestedDay {
                Button {
                    var cal = Calendar(identifier: .gregorian)
                    cal.timeZone = timeZone
                    pick(cal.startOfDay(for: suggested))
                } label: {
                    chipLabel("Suggested")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to the suggested rebook date")
                .accessibilityHint("The service date plus this offering’s usual rebook interval")
            }
            Spacer(minLength: 0)
        }
    }

    private func chipLabel(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.body(12, .semibold))
            .foregroundStyle(BrandColor.accent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(BrandColor.accent.opacity(0.12))
            .clipShape(Capsule())
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
                if openSlotsComputed {
                    legendItem(color: BrandColor.emerald, label: "Open times")
                } else {
                    legendItem(color: BrandColor.accent, label: "Booked")
                }
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
                from: first.dayYmd, to: last.dayYmd, tz: timeZone.identifier,
                slotContext: slotContext)
            busy = response.days
            openSlotsComputed = response.openSlots?.computed == true
        } catch {
            // The overlay is optional — a failure leaves the grid usable, which
            // is exactly what the web popup does on a non-OK response.
            busy = [:]
            openSlotsComputed = false
        }
    }
}

/// The same calendar as a presented sheet: picking a day also dismisses it.
/// Used where the value lives in a row of its own (the recommended window's END
/// date), matching web's modal `AvailabilityCalendarPopup` on that field.
struct ProRebookCalendarSheet: View {
    @Environment(\.dismiss) private var dismiss

    let timeZone: TimeZone
    let offWeekdays: Set<Int>
    let selectedDay: Date
    let earliest: Date
    var suggestedDay: Date? = nil
    var title = "My calendar"
    let onPick: (Date) -> Void
    var slotContext: ProBusyDaysSlotContext? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                ProRebookCalendarView(
                    timeZone: timeZone,
                    offWeekdays: offWeekdays,
                    selectedDay: selectedDay,
                    earliest: earliest,
                    suggestedDay: suggestedDay,
                    onPick: { day in
                        onPick(day)
                        dismiss()
                    },
                    slotContext: slotContext
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.tint(BrandColor.accent)
                }
            }
        }
    }
}
