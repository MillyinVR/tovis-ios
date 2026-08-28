// A reusable open-appointment-slot picker — the pro's own availability calendar
// + a date stepper + their real available start times for a service + location,
// fetched from GET /api/v1/availability/day (via the shared BookingService.day).
// Used by the new-booking form, the reschedule screen, the waitlist offer sheet
// and the aftercare "Next booking date" rebook mode. The binding holds the
// chosen ISO start instant (nil = nothing picked).
//
// R3: the day is picked on `ProRebookCalendarView`, so every pro-facing time
// picker shows where they are ALREADY booked or blocked before they choose —
// web parity with `app/pro/_components/AvailabilityCalendar`. The compact date
// stepper below it stays as the typed fallback.
import SwiftUI
import TovisKit

struct ProOpenSlotPicker: View {
    @Environment(SessionModel.self) private var session

    let professionalId: String
    let serviceId: String
    let offeringId: String
    let locationId: String
    let locationType: String
    /// Timezone the availability `date` param is interpreted in (location zone).
    let locationTimeZone: String?
    /// For a MOBILE booking, the client's saved service-address id so slots respect
    /// the pro's travel radius. nil for SALON (or an as-yet-unsaved MOBILE address).
    var clientAddressId: String? = nil
    /// Set when a PRO is picking a time to OFFER a waitlisted client. MOBILE
    /// placement needs the client's service address, and at offer time the pro is
    /// not entitled to it — so this entry id goes to the server instead and the
    /// destination is resolved there. It REPLACES `clientAddressId` on that path;
    /// nothing about the client's address exists on this device to pass.
    var waitlistEntryId: String? = nil
    /// Weekday indexes (0=Sun … 6=Sat) the pro's weekly schedule marks disabled.
    /// An off day legitimately has zero open times — with this set, the empty
    /// state says WHY (and `offDayHint` can point at the surface's escape
    /// hatch, e.g. the aftercare form's "Custom time"). When the caller passes
    /// nothing the picker loads the location's week itself (best-effort), so
    /// every surface gets the dashed off-day shading, not just aftercare.
    var offWeekdays: Set<Int> = []
    var offDayHint: String? = nil
    /// Whether this picker owns the inline availability calendar (R3). Default
    /// on: every surface wants it. The aftercare rebook passes `false` because
    /// it hoists the SAME calendar above its "Enter a custom time" toggle, so
    /// the day stays pickable in custom mode too — letting the picker draw a
    /// second one there would show two calendars in slot mode.
    var showCalendar = true
    /// Set when this picker is MOVING an existing booking (the reschedule
    /// screen). The calendar's open-slot counts are then sized from that
    /// booking's committed width, and it stops blocking its own day — without
    /// it the day the appointment already sits on counts as fuller than it is.
    var rescheduleBookingId: String? = nil
    /// Set when this picker books the NEXT appointment from a booking's
    /// aftercare. The rebook commit CLONES that booking (base + add-ons at
    /// snapshot durations), so both the day's open times and the calendar's
    /// counts are sized from the clone width — offering-base sizing advertises
    /// starts the save doesn't fit.
    var rebookOfBookingId: String? = nil
    /// The chosen slot's ISO start instant.
    @Binding var selectedSlot: String?
    /// The day whose open times are shown. Owned by the caller so another
    /// surface can drive it — the aftercare rebook sheet picks a day off the
    /// pro's own month calendar and the stepper follows. ⚠️ Hoisting this out
    /// of the picker means the day now SURVIVES the picker being swapped out
    /// (e.g. toggling a manual/custom-time mode) instead of resetting to today.
    @Binding var selectedDate: Date

    @State private var slots: [String] = []
    @State private var slotTimeZone: String?
    @State private var loadingSlots = false
    @State private var slotError: String?
    /// The location's disabled weekdays, self-loaded when the caller passed
    /// none. Best-effort — a failure just skips the shading, same as aftercare.
    @State private var loadedOffWeekdays: Set<Int> = []

    /// The zone the availability `date` param is interpreted in. The picker is
    /// pinned to it so the day the pro taps is the day fetched — unpinned, a
    /// device zone straddling midnight against the location's fetches the
    /// neighboring day.
    private var dayZone: TimeZone { TimeZone(identifier: locationTimeZone ?? "") ?? .current }

    /// What the inline calendar counts open slots FOR (R4) — the same service
    /// and location this picker is already fetching day slots for, so the grid
    /// and the chips below it can never be answering different questions.
    /// nil until the service is known: an empty `serviceId` must not ship
    /// `serviceId=` to the server (same guard the aftercare surface applies).
    private var slotContext: ProBusyDaysSlotContext? {
        guard !serviceId.isEmpty else { return nil }
        return ProBusyDaysSlotContext(
            serviceId: serviceId,
            locationType: locationType,
            locationId: locationId,
            rescheduleBookingId: rescheduleBookingId,
            rebookOfBookingId: rebookOfBookingId
        )
    }

    /// The caller's off-day set when it has one, else the self-loaded one.
    private var effectiveOffWeekdays: Set<Int> {
        offWeekdays.isEmpty ? loadedOffWeekdays : offWeekdays
    }

    /// Re-fetch whenever the service/location/date inputs change. The rebook
    /// source is part of the key — it changes the width the day is computed for.
    private var fetchKey: String {
        "\(professionalId)|\(serviceId)|\(offeringId)|\(locationId)|\(locationType)|\(clientAddressId ?? "")|\(waitlistEntryId ?? "")|\(rebookOfBookingId ?? "")|\(ymd(selectedDate))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showCalendar {
                ProRebookCalendarView(
                    timeZone: dayZone,
                    offWeekdays: effectiveOffWeekdays,
                    selectedDay: selectedDate,
                    // Today — the same floor the date stepper below is pinned to
                    // (`in: Date()...`). The calendar clamps its own pick to it,
                    // so a tap on today hands back "now", not this morning's
                    // midnight, which the stepper's range would refuse.
                    earliest: Date(),
                    onPick: { selectedDate = $0 },
                    // R4: count the bookable starts for THIS service+location,
                    // so the grid shows where the appointment actually fits
                    // rather than only where the day is already busy.
                    slotContext: slotContext
                )
            }
            BrandSurface {
                DatePicker("", selection: $selectedDate, in: Date()..., displayedComponents: [.date])
                    .labelsHidden().tint(BrandColor.accent)
                    .environment(\.timeZone, dayZone)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            slotGrid
        }
        .task(id: fetchKey) { await fetchSlots() }
        .task(id: "\(locationType)|\(locationId)") { await loadOffWeekdaysIfNeeded() }
    }

    @ViewBuilder
    private var slotGrid: some View {
        if offeringId.isEmpty {
            hint("This booking has no service offering set, so an exact time can’t be proposed.")
        } else if loadingSlots {
            HStack(spacing: 8) {
                ProgressView().tint(BrandColor.accent)
                Text("Loading open times…").font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
            }
        } else if let slotError {
            Text(slotError).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
        } else if slots.isEmpty {
            if selectedDayIsOff {
                hint(offDayHint ?? "This day is outside your working hours.")
            } else {
                hint("No open times on this day. Try another date.")
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                ForEach(slots, id: \.self) { slot in
                    Button { selectedSlot = slot } label: {
                        Text(slotLabel(slot))
                            .font(BrandFont.body(13, .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(selectedSlot == slot ? BrandColor.accent : BrandColor.bgSecondary)
                            .foregroundStyle(selectedSlot == slot ? BrandColor.onAccent : BrandColor.textPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
    }

    /// Whether the picked day falls on a weekday the schedule disables —
    /// judged in the location's zone, matching how the day was fetched.
    private var selectedDayIsOff: Bool {
        let off = effectiveOffWeekdays
        guard !off.isEmpty else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = dayZone
        // Calendar.weekday is 1-based (1 = Sunday).
        return off.contains(cal.component(.weekday, from: selectedDate) - 1)
    }

    /// Load the location's weekly schedule for off-day shading when the caller
    /// didn't supply one (new booking, reschedule, waitlist offer). Aftercare
    /// keeps passing its own set — it also shades its hoisted calendar with it.
    private func loadOffWeekdaysIfNeeded() async {
        guard offWeekdays.isEmpty, !locationId.isEmpty else { return }
        do {
            let response = try await session.client.proSchedule.workingHours(
                locationType: locationType,
                locationId: locationId,
            )
            loadedOffWeekdays = response.workingHours.disabledWeekdayIndexes
        } catch {
            // Off-day shading is optional guidance — the save-side checks still
            // cover an off-day pick.
        }
    }

    private func fetchSlots() async {
        // A fresh fetch (new service/location/date) invalidates any prior pick.
        selectedSlot = nil
        slotError = nil
        guard !offeringId.isEmpty, !locationId.isEmpty, !professionalId.isEmpty else {
            slots = []
            return
        }
        loadingSlots = true
        defer { loadingSlots = false }
        do {
            let day = try await session.client.booking.day(
                professionalId: professionalId,
                serviceId: serviceId,
                offeringId: offeringId,
                locationId: locationId,
                date: ymd(selectedDate),
                locationType: locationType,
                clientAddressId: clientAddressId,
                rebookOfBookingId: rebookOfBookingId,
                waitlistEntryId: waitlistEntryId,
            )
            slots = day.slots
            slotTimeZone = day.timeZone
        } catch let error as APIError {
            slots = []
            slotError = error.userMessage
        } catch {
            slots = []
            slotError = "Couldn’t load open times."
        }
    }

    /// "h:mm a" in the slot's (location) timezone.
    private func slotLabel(_ iso: String) -> String {
        guard let date = Wire.date(iso) else { return iso }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: slotTimeZone ?? locationTimeZone ?? "") ?? .current
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    /// "yyyy-MM-dd" for the chosen date in the location's timezone (how the
    /// availability endpoint interprets the `date` param).
    private func ymd(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = dayZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
