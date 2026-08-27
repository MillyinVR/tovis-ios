// Booking flow (v1, request-to-book) — pick a date + time for an offering, hold
// it, then add add-ons on their own screen and finalize. Opened as a sheet from
// the pro profile / a look. Salon + mobile, no in-app payment (handled per the
// pro's settings / at appointment); Stripe checkout lands via the tovis://
// deep-link return.
//
// Built to `BookingSheetFrame`, and to the web AvailabilityDrawer it mirrors:
// a cover photo of the look being booked, the service line with the pro's
// rating, the reassurance chips, a horizontal day scroller carrying each day's
// remaining supply, Morning · Afternoon · Evening tabs, the held-time recap with
// its countdown, then one sticky CTA.
//
// ⚠️ Picking a time PLACES A HOLD, exactly as tapping a slot does on web. The
// selection and the reservation are the same thing here — there is no state
// where a slot looks chosen but is not actually reserved — so every path that
// abandons a selection (a new pick, a placement change, closing the sheet) has
// to give the old hold back.
import SwiftUI
import TovisKit

struct BookingFlowView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let professionalId: String
    let proName: String
    let offering: ProOffering
    /// When set, this flow RESCHEDULES that booking (hold → reschedule) instead
    /// of creating a new one (hold → add-ons → finalize). The picker is
    /// otherwise identical; a reschedule keeps the booking's original add-ons,
    /// so it never reaches the add-ons step.
    var rescheduleBookingId: String? = nil
    /// The booking's location mode, preserved across a reschedule. Defaults to SALON.
    var locationType: String = "SALON"
    /// When set, the flow opens on this ISO instant's day and picks it when it's
    /// still bookable — used by the openings feed to land the client on the
    /// freed-up slot (mirrors the web `?scheduledFor=` deep-link). General
    /// availability drives the hold, so a slot that's no longer open simply
    /// isn't picked and the client chooses another time.
    var preselectedSlot: String? = nil
    /// When set, the day scroller's window STARTS on this "yyyy-MM-dd" (in the
    /// location's zone) instead of today — the aftercare rebook opens on the
    /// window the pro recommended. Resolve it with `RebookWindowAnchor`: the
    /// route refuses a past date outright, and the window is only seven days
    /// wide, so a rebook eight weeks out is not merely mis-anchored without it,
    /// it is entirely outside the days the scroller can reach.
    var initialStartDate: String? = nil
    /// The primary MediaAsset id of the LOOK this booking started from. It is
    /// what the server resolves the sheet's cover photo and look name from
    /// (`lib/booking/bookingCover.ts`) — without it the sheet cannot say which
    /// look you are booking, and falls back to the service's name over a plain
    /// header. `nil` when the flow was entered from a pro's profile, an
    /// appointment or an opening rather than from a look.
    var lookMediaId: String? = nil
    /// The `LastMinuteOpening.id` when this flow is CLAIMING a last-minute opening
    /// (openings feed / priority offer). Passed through to `finalize` so the server
    /// consumes the opening and applies the tier incentive the client was shown —
    /// without it the opening stays claimable and the discount is silently dropped.
    /// `nil` for an ordinary booking or a reschedule.
    var openingId: String? = nil

    private var isReschedule: Bool { rescheduleBookingId != nil }

    private enum Phase {
        case loading
        case ready(AvailabilityBootstrap)
        /// MOBILE with no service address yet — availability can't even be asked
        /// for until the client picks one, so the flow gates on it.
        case needsAddress
        case failed(String)
        /// Carries the (re)scheduled instant ISO — works for finalize + reschedule.
        case success(scheduledFor: String, bookingId: String?, professionalId: String?)
    }

    /// The one pushed step. The add-ons screen reads the hold + bootstrap out of
    /// this view's state, so the route itself carries nothing.
    private enum Route: Hashable { case addOns }

    @State private var phase: Phase = .loading
    @State private var path: [Route] = []

    /// The day the grid is showing — a YYYY-MM-DD in the LOCATION's zone, which
    /// is what `availableDays` and the `day` request both speak.
    @State private var selectedYMD: String?
    @State private var slots: [String] = []
    @State private var period: BookingSheetPresentation.DayPeriod = .morning
    @State private var loadingSlots = false
    /// Non-nil when the availability fetch itself failed (vs. a genuinely empty
    /// day) — surfaced with a retry instead of a misleading "no openings".
    @State private var slotError: String?

    /// The reservation. `selectedSlot` is derived from it: on this screen a slot
    /// is selected exactly when it is held.
    @State private var hold: BookingHold?
    @State private var holdExpiresAt: Date?
    /// Set once the hold has become a booking — it must NOT be released then.
    @State private var holdConsumed = false
    @State private var holding = false

    @State private var booking = false
    @State private var bookError: String?
    /// The APPOINTMENT's timezone (the booking location's), kept out of `phase`
    /// so the success screen still has it after `.ready(boot)` is gone.
    ///
    /// ⚠️ The confirmation used to render its WHEN row with `timeZone: nil`,
    /// i.e. the DEVICE's zone — a 9:00 AM New York appointment read "6:00 AM" on
    /// a simulator set to Los Angeles. A booking's time belongs to where it
    /// happens, never to where the phone happens to be.
    @State private var appointmentTimeZone: String?
    /// The salon this booking is going to, remembered from the bootstrap for the
    /// same reason as the timezone: the success screen outlives `.ready(boot)`.
    @State private var salonAddressLine: String?
    /// The pro's MOBILE travel reach, remembered the same way — `placementControls`
    /// renders even before a `boot` exists (the address-gate empty state), so this
    /// can't just be read off `boot` inline.
    @State private var serviceArea: AvailabilityServiceArea?
    /// Minutes of add-ons the client actually booked, reported back by the
    /// add-ons step. The base width alone under-states the appointment on the
    /// confirmation card (a 180-minute service booked with 45 minutes of add-ons
    /// is a 225-minute appointment).
    @State private var bookedAddOnMinutes = 0
    @State private var showConsult = false
    /// Server-decided consult entry for the just-created booking (GET
    /// /client/consult/availability). Fail-closed: stays false until the
    /// server explicitly answers true.
    @State private var consultAvailable = false
    /// Guards the one-time preselect so a later day change / manual pick wins.
    @State private var didApplyPreselect = false

    // Add-ons (new bookings only — reschedule keeps the original add-ons). Loaded
    // here so the CTA knows whether there is a second step at all.
    @State private var addOns: [BookingAddOn] = []

    // M15: the pro's no-show/late-cancel fee policy the client must agree to
    // before booking. nil → the pro charges no fees → no gate. Presented on the
    // add-ons step, where the booking is actually completed.
    @State private var cancellationPolicy: String?

    // Location mode (SALON / MOBILE). New bookings can choose when the offering
    // offers both; reschedule keeps the original. MOBILE needs a service address.
    @State private var mode = ""
    @State private var addresses: [ClientAddress] = []
    @State private var selectedAddressId: String?
    @State private var loadingAddresses = false
    /// Set when the address fetch itself failed (vs. the client genuinely having
    /// none) — surfaced with a retry, like `slotError` does for a failed day.
    @State private var addressLoadFailed = false
    @State private var showAddAddress = false

    private var duration: Int { offering.durationMinutes ?? 60 }

    private var isMobile: Bool { mode.uppercased() == "MOBILE" }

    private var selectedSlot: String? { hold?.scheduledFor }

    /// Show the SALON/MOBILE switch only for a new booking on an offering that
    /// supports both. A reschedule preserves the original mode.
    private var canChooseMode: Bool {
        !isReschedule && offering.offersInSalon && offering.offersMobile
    }

    /// The mode a new flow opens in. Reschedule keeps the booking's existing
    /// mode; a rebook passes the original booking's mode as `locationType`, so
    /// honor a MOBILE hint whenever the offering still offers it (previously a
    /// mobile rebook on a dual-mode offering silently opened in SALON). Plain
    /// new bookings keep the SALON-when-offered default (`locationType`'s
    /// default is SALON, so untouched callers behave identically).
    private var initialMode: String {
        if isReschedule { return locationType }
        if locationType.uppercased() == "MOBILE" && offering.offersMobile { return "MOBILE" }
        if offering.offersInSalon { return "SALON" }
        if offering.offersMobile { return "MOBILE" }
        return locationType
    }

    /// A mobile booking can't proceed until a service address is chosen.
    private var addressRequiredButMissing: Bool { isMobile && selectedAddressId == nil }

    /// The width to SHOW. A reschedule commits the booking's own duration, which
    /// drifts from the offering's base whenever the pro edits the service — so
    /// showing the base put "60 min" above a 90-minute appointment and made the
    /// (correctly narrowed) grid look wrong (B3-A). The server echoes the width
    /// it actually sized the offer with, so read that once it has answered.
    ///
    /// Add-ons no longer widen this number on the PICKER: they are chosen on the
    /// next step, and the hold is re-sized there. The confirmation is a
    /// different question — see `bookedDuration`.
    private var displayDuration: Int {
        guard case let .ready(boot) = phase else { return baseDuration }
        return boot.request.durationMinutes
    }

    /// The width of the appointment that was actually BOOKED — the base plus the
    /// add-ons the client kept. `phase` is `.success` by the time this renders,
    /// so it cannot read the bootstrap echo.
    private var bookedDuration: Int { baseDuration + bookedAddOnMinutes }

    /// The base width the bootstrap echoed, remembered across the phase change.
    @State private var baseDurationState: Int?

    private var baseDuration: Int {
        if case let .ready(boot) = phase { return boot.request.durationMinutes }
        return baseDurationState ?? duration
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch phase {
                case .loading:
                    ProgressView().tint(BrandColor.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message):
                    failure(message)
                case let .success(scheduledFor, bookingId, professionalId):
                    success(scheduledFor, bookingId: bookingId, professionalId: professionalId)
                case .needsAddress:
                    addressGate
                case let .ready(boot):
                    sheet(boot)
                }
            }
            // Attached above the phase switch so the "add an address" route works
            // from the gate screen too, not just the loaded form.
            .sheet(isPresented: $showAddAddress) {
                AddServiceAddressSheet { newAddress in
                    addresses.insert(newAddress, at: 0)
                    // We hold an address again, so a stale fetch failure must not
                    // keep showing "couldn't load" over a list that now has one.
                    addressLoadFailed = false
                    selectAddress(newAddress.id)
                }
            }
            .sheet(isPresented: $showConsult) {
                if case let .success(_, bookingId?, professionalId?) = phase {
                    ConsultFlowView(bookingId: bookingId, professionalId: professionalId)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(showsNavigationBar ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if showsNavigationBar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { close() }.tint(BrandColor.textSecondary)
                    }
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .addOns:
                    addOnsStep
                }
            }
            .task { if case .loading = phase { await loadBootstrap() } }
        }
        .tint(BrandColor.accent)
        // The sheet's own hold is a reservation somebody else could be waiting
        // for. Give it back the moment this flow goes away without booking.
        .onDisappear { releaseHoldInBackground() }
    }

    /// The picker draws its own header with a ✕ over the cover, as the frame does,
    /// so it hides the bar. Every other phase keeps the bar for its way out.
    private var showsNavigationBar: Bool {
        if case .ready = phase { return false }
        return true
    }

    private var navigationTitle: String { isReschedule ? "Reschedule" : "Book" }

    // MARK: - The sheet

    private func sheet(_ boot: AvailabilityBootstrap) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    BookingSheetCover(
                        cover: boot.cover,
                        trust: boot.trust,
                        serviceName: boot.serviceName ?? offering.name,
                        proName: proName,
                        proAvatarUrl: boot.primaryPro?.avatarUrl,
                        priceFromLabel: offering.priceFromLabel,
                        durationMinutes: displayDuration,
                        onClose: { close() }
                    )

                    VStack(alignment: .leading, spacing: 20) {
                        placementControls

                        Text("When works?")
                            .font(BrandFont.display(28, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)

                        dayScroller(boot)

                        timesSection(boot)

                        heldRecap(boot)

                        if let bookError {
                            BrandErrorBanner(message: bookError)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 20)
            }

            stickyCTA(boot)
        }
    }

    /// Mode switch + address picker — the part of the flow that must render
    /// BEFORE availability is known, because on MOBILE the address is an INPUT to
    /// the availability request rather than a later step.
    @ViewBuilder
    private var placementControls: some View {
        if canChooseMode {
            BrandSection(title: "Where") {
                Picker("Where", selection: $mode) {
                    Text("At the salon").tag("SALON")
                    Text("Mobile (they come to you)").tag("MOBILE")
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { Task { await loadBootstrap() } }
            }
        }

        whereBlock

        if isMobile {
            BrandSection(title: "Service address", trailing: "Required") {
                addressSection
            }
        }
    }

    /// Where this appointment happens — on the sheet, before the client commits.
    /// iOS twin of web's `WhereBlock.tsx` (Tori, 2026-08-14: *"when a client
    /// chooses a pro from the looks feed or lands on the booking option they
    /// salon address or if they are mobile a city radius should show. if the
    /// client doesnt know where the pro is located they wont book. the address
    /// should be clickable."*).
    ///
    /// MOBILE mode always renders `addressSection` (the client's OWN address)
    /// directly below this — deliberately not repeated here, this block states
    /// only the pro's standing travel reach. Nothing renders when neither an
    /// address nor an area is known, matching web's "nothing to say beats a
    /// half-filled promise."
    @ViewBuilder
    private var whereBlock: some View {
        if isMobile {
            if let area = serviceArea, area.radiusMiles != nil || area.areaLabel != nil {
                BrandSurface {
                    whereRow(icon: "car.fill", title: mobileReachTitle(area))
                }
            }
        } else if let title = salonAddressLine {
            // `salonAddressLine` already prefers the exact street address and
            // falls back to the coarse area (`AvailabilityLocationOption.addressLine`)
            // — 🔴 area always, exact address only when the pro published it.
            BrandSurface {
                if let url = MapsLink.url(address: title) {
                    Link(destination: url) {
                        whereRow(icon: "mappin.circle.fill", title: title, isLink: true)
                    }
                    .buttonStyle(.plain)
                } else {
                    whereRow(icon: "mappin.circle.fill", title: title)
                }
            }
        }
    }

    private func mobileReachTitle(_ area: AvailabilityServiceArea) -> String {
        switch (area.radiusMiles, area.areaLabel?.trimmedOrNil) {
        case let (.some(radius), .some(label)):
            return "Travels up to \(radius) mi around \(label)"
        case let (.some(radius), .none):
            return "Travels up to \(radius) mi"
        case let (.none, .some(label)):
            return "Travels around \(label)"
        case (.none, .none):
            return "" // unreachable — callers guard on radius/area being present
        }
    }

    private func whereRow(icon: String, title: String, isLink: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(isLink ? BrandColor.accent : BrandColor.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(isLink ? BrandColor.accent : BrandColor.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if isLink {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12))
                    .foregroundStyle(BrandColor.accent)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .frame(minHeight: isLink ? 30 : 0)
    }

    /// Shown when a MOBILE booking has no service address to compute availability
    /// against. The server refuses the availability request outright without one,
    /// so the flow asks here instead of dead-ending on a full-screen error.
    private var addressGate: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                BrandSurface {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(offering.name)
                            .font(BrandFont.body(17, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        Text("with \(proName)")
                            .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                    }
                }

                placementControls

                if !addressLoadFailed {
                    // No pro-name interpolation — some entry points open this flow
                    // without one, which would read "…you’d like  to come to".
                    Text("Add the address you’d like to be seen at, and we’ll show the times that work for it.")
                        .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Day scroller

    @ViewBuilder
    private func dayScroller(_ boot: AvailabilityBootstrap) -> some View {
        if boot.availableDays.isEmpty {
            Text("No open days in the next few weeks. Try another service or check back soon.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(boot.availableDays) { day in
                        dayButton(day, boot: boot)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func dayButton(_ day: AvailabilityDaySummary, boot: AvailabilityBootstrap) -> some View {
        let active = day.date == selectedYMD
        let scarce = BookingSheetPresentation.daySupplyIsScarce(slotCount: day.slotCount)
        return Button {
            guard day.date != selectedYMD else { return }
            selectedYMD = day.date
            Task {
                // The chosen time belongs to the old day, so the reservation does
                // too — give it back rather than leaving it parked.
                await releaseCurrentHold()
                await loadSlots(boot)
            }
        } label: {
            VStack(spacing: 4) {
                Text(dayWeekday(day.date, tz: boot.timeZone))
                    .font(BrandFont.mono(10)).tracking(0.8)
                    .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textSecondary)
                Text(dayNumber(day.date, tz: boot.timeZone))
                    .font(BrandFont.body(18, .bold))
                    .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textPrimary)
                Text(BookingSheetPresentation.daySupplyLabel(slotCount: day.slotCount))
                    .font(BrandFont.mono(9)).tracking(0.4)
                    .foregroundStyle(supplyTint(active: active, scarce: scarce))
            }
            .frame(minWidth: 58)
            .padding(.vertical, 10).padding(.horizontal, 10)
            .background(active ? BrandColor.accent : BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(active ? Color.clear : BrandColor.textMuted.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(dayWeekday(day.date, tz: boot.timeZone)) \(dayNumber(day.date, tz: boot.timeZone)), "
            + BookingSheetPresentation.daySupplyLabel(slotCount: day.slotCount)
        )
    }

    private func supplyTint(active: Bool, scarce: Bool) -> Color {
        if active { return BrandColor.onAccent.opacity(0.75) }
        return scarce ? BrandColor.gold : BrandColor.textMuted
    }

    // MARK: - Times

    @ViewBuilder
    private func timesSection(_ boot: AvailabilityBootstrap) -> some View {
        let grouped = BookingSheetPresentation.groupSlotsByPeriod(slots, timeZone: boot.timeZone)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(BookingSheetPresentation.DayPeriod.allCases, id: \.self) { item in
                    periodButton(item, empty: (grouped[item] ?? []).isEmpty)
                }
            }

            if let timeZoneLabel = timeZoneLabel(boot) {
                Text("Times shown in \(timeZoneLabel)")
                    .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
            }

            if loadingSlots {
                ProgressView().tint(BrandColor.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else if let slotError {
                // A failed fetch is not an empty day — say so, and offer a retry.
                VStack(alignment: .leading, spacing: 8) {
                    Text(slotError)
                        .font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    Button("Try again") { Task { await loadSlots(boot) } }
                        .font(BrandFont.body(13, .semibold)).tint(BrandColor.accent)
                }
                .padding(.vertical, 8)
            } else {
                slotGrid(grouped[period] ?? [], boot: boot, dayIsEmpty: slots.isEmpty)
            }
        }
    }

    private func periodButton(
        _ item: BookingSheetPresentation.DayPeriod,
        empty: Bool
    ) -> some View {
        let active = item == period
        return Button {
            guard !empty, !active else { return }
            period = item
        } label: {
            Text(item.label)
                .font(BrandFont.mono(10)).tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(active ? BrandColor.accent : BrandColor.bgSurface)
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(active ? Color.clear : BrandColor.textMuted.opacity(0.18), lineWidth: 1)
                )
                .opacity(empty ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(empty)
    }

    @ViewBuilder
    private func slotGrid(
        _ visible: [String],
        boot: AvailabilityBootstrap,
        dayIsEmpty: Bool
    ) -> some View {
        if visible.isEmpty {
            Text(dayIsEmpty ? "No available times for this day." : period.emptyCopy)
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                .padding(.vertical, 8)
        } else {
            // .adaptive keeps 3 columns on a phone-width container and adds columns
            // on a wider one — iPad — instead of stretching 3 tiles across the extra
            // width.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                ForEach(visible, id: \.self) { slot in
                    let isSelected = slot == selectedSlot
                    Button { Task { await pickSlot(slot, boot: boot) } } label: {
                        Text(slotLabel(slot, tz: boot.timeZone))
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(isSelected ? BrandColor.onAccent : BrandColor.textPrimary)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(isSelected ? BrandColor.accent : BrandColor.bgSurface)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(
                                    isSelected ? Color.clear : BrandColor.textMuted.opacity(0.18),
                                    lineWidth: 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(holding || booking)
                }
            }
            .opacity(holding ? 0.6 : 1)
        }
    }

    // MARK: - Held recap

    @ViewBuilder
    private func heldRecap(_ boot: AvailabilityBootstrap) -> some View {
        if holding {
            BrandSurface {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Holding your time…")
                        .font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    Text("Please wait while we reserve this slot.")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                }
            }
        } else if let hold, let holdExpiresAt {
            VStack(alignment: .leading, spacing: 6) {
                Text("Time held · \(Wire.dateTime(hold.scheduledFor, timeZone: boot.timeZone))")
                    .font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)

                // A live countdown, so the client can see how long they have —
                // TimelineView re-renders this text alone, once a second.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = Int(holdExpiresAt.timeIntervalSince(context.date).rounded(.down))
                    if remaining > 0 {
                        HStack(spacing: 4) {
                            Text("Continue before")
                                .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                            Text(BookingSheetPresentation.holdCountdownLabel(secondsRemaining: remaining))
                                .font(BrandFont.mono(12))
                                .foregroundStyle(
                                    BookingSheetPresentation.holdIsUrgent(secondsRemaining: remaining)
                                        ? BrandColor.ember : BrandColor.textPrimary
                                )
                                .monospacedDigit()
                        }
                    } else {
                        Text("That hold expired. Pick a new time.")
                            .font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.ember)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(BrandColor.accent.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(BrandColor.accent.opacity(0.35), lineWidth: 1)
            )
        }
    }

    // MARK: - CTA

    private func stickyCTA(_ boot: AvailabilityBootstrap) -> some View {
        VStack(spacing: 8) {
            if let selectedSlot {
                Text("Held: \(Wire.dateTime(selectedSlot, timeZone: boot.timeZone))")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
            }

            Button { Task { await advance(boot) } } label: {
                Group {
                    if booking || holding {
                        ProgressView().tint(BrandColor.onAccent)
                    } else {
                        Text(ctaLabel).font(BrandFont.body(16, .semibold))
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .foregroundStyle(ctaDisabled ? BrandColor.textMuted : BrandColor.onAccent)
                .background(ctaDisabled ? BrandColor.textMuted.opacity(0.18) : BrandColor.accent)
                .clipShape(Capsule())
            }
            .disabled(ctaDisabled)

            if hold == nil {
                Text("No charge yet · The pro confirms first")
                    .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(BrandColor.bgPrimary)
        .overlay(alignment: .top) {
            Rectangle().fill(BrandColor.textMuted.opacity(0.15)).frame(height: 1)
        }
    }

    private var ctaLabel: String {
        if hold == nil { return "Pick a time to continue" }
        return isReschedule ? "Confirm new time" : "Continue to add-ons"
    }

    private var ctaDisabled: Bool {
        hold == nil || holding || booking || addressRequiredButMissing
    }

    // MARK: - Add-ons step

    @ViewBuilder
    private var addOnsStep: some View {
        if case let .ready(boot) = phase, let hold, let holdExpiresAt {
            BookingAddOnsView(
                context: BookingAddOnsContext(
                    coverImageUrl: boot.cover?.imageUrl,
                    lookName: boot.cover?.lookName,
                    serviceName: boot.serviceName ?? offering.name,
                    proName: proName,
                    whenLabel: Wire.dateTime(hold.scheduledFor, timeZone: boot.timeZone)
                ),
                holdId: hold.id,
                holdExpiresAt: holdExpiresAt,
                offeringId: offering.id,
                locationType: mode,
                addOns: addOns,
                cancellationPolicy: cancellationPolicy,
                openingId: openingId,
                onBooked: { booked, addOnMinutes in
                    holdConsumed = true
                    bookedAddOnMinutes = addOnMinutes
                    session.signalRefresh() // surface the change in Appointments/Home
                    phase = .success(
                        scheduledFor: booked.scheduledFor,
                        bookingId: booked.id,
                        professionalId: booked.professionalId
                    )
                    path.removeAll()
                }
            )
        } else {
            // Only reachable if the hold went away under the push (expired and
            // cleared). Say so rather than showing an add-ons screen that cannot
            // book anything.
            VStack(spacing: 12) {
                Text("That hold is no longer available.")
                    .font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
                Button("Pick another time") { path.removeAll() }
                    .font(BrandFont.body(15, .semibold)).tint(BrandColor.accent)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
        }
    }

    // MARK: - Address picker (mobile)

    @ViewBuilder
    private var addressSection: some View {
        if loadingAddresses {
            ProgressView().tint(BrandColor.accent).frame(maxWidth: .infinity).padding(.vertical, 16)
        } else if addressLoadFailed {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn’t load your saved addresses.")
                    .font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                Button("Try again") { Task { await loadBootstrap() } }
                    .font(BrandFont.body(13, .semibold)).tint(BrandColor.accent)
            }
            .padding(.vertical, 8)
        } else {
            VStack(spacing: 10) {
                ForEach(addresses) { address in
                    addressRow(address)
                }
                Button { showAddAddress = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text(addresses.isEmpty ? "Add a service address" : "Add another address")
                            .font(BrandFont.body(14, .medium))
                    }
                    .foregroundStyle(BrandColor.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func addressRow(_ address: ClientAddress) -> some View {
        let isSelected = selectedAddressId == address.id
        return Button { selectAddress(address.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? BrandColor.accent : BrandColor.textMuted.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(address.displayLine)
                        .font(BrandFont.body(15, .medium)).foregroundStyle(BrandColor.textPrimary)
                    if let detail = address.detailLine {
                        Text(detail).font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isSelected ? BrandColor.accent.opacity(0.6) : BrandColor.textMuted.opacity(0.18),
                        lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Success / failure

    /// Matches the web confirmation screen (`app/booking/[id]/page.tsx`): the
    /// honest hero, a summary card, then the three "what happens next" steps.
    /// A RESCHEDULE is already confirmed, so it keeps the hero and the card but
    /// drops the pending pill and the steps — nothing is waiting on the pro.
    private func success(_ scheduledFor: String, bookingId: String?,
                         professionalId: String?) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56)).foregroundStyle(BrandColor.accent)

                Text(isReschedule ? "Time updated" : "Request sent")
                    .font(BrandFont.display(24, .semibold)).foregroundStyle(BrandColor.textPrimary)

                Text(isReschedule
                     ? "Your booking was moved. \(proName) will be notified."
                     : "\(proName) has your request — nothing’s charged until they confirm.")
                    .font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if !isReschedule {
                    HStack(spacing: 7) {
                        Circle().fill(BrandColor.gold).frame(width: 6, height: 6)
                        Text("PENDING CONFIRMATION")
                            .font(BrandFont.mono(10)).tracking(1.2)
                            .foregroundStyle(BrandColor.gold)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 7)
                    .overlay(Capsule().stroke(BrandColor.gold.opacity(0.4), lineWidth: 1))
                }

                successSummaryCard(scheduledFor)

                if !isReschedule { successNextSteps }

                if !isReschedule, consultAvailable, bookingId != nil {
                    Button { showConsult = true } label: {
                        Label("Add beauty consult", systemImage: "sparkles")
                            .font(BrandFont.body(16, .semibold))
                            .foregroundStyle(BrandColor.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(BrandColor.accent, lineWidth: 1)
                            )
                    }
                    .accessibilityIdentifier("booking-add-ai-consult")
                }

                Button { dismiss() } label: {
                    Text("Done").font(BrandFont.body(16, .semibold)).foregroundStyle(BrandColor.onAccent)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(BrandColor.accent).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.top, 4)
            }
            .padding(28)
        }
        // The consult entry is server-decided (founder gate + booking
        // eligibility live in tovis-app, incl. the recorded eval deferral), so
        // the device asks instead of shipping its own copy of the gate.
        // Fail-closed: no answer, or any error, keeps the entry hidden.
        .task(id: bookingId) {
            guard !isReschedule, let bookingId else { return }
            consultAvailable = (try? await session.client.consult
                .availability(bookingId: bookingId).available) ?? false
        }
    }

    /// Service · price · duration, then WHEN / WHERE — the same rows the web
    /// summary card shows, in the same order.
    private func successSummaryCard(_ scheduledFor: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(offering.name)
                        .font(BrandFont.display(16, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("with \(proName)")
                        .font(BrandFont.body(12.5)).foregroundStyle(BrandColor.textSecondary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    // ⚠️ A STARTING price — the pro sets the final one. The wire
                    // sends a bare "$250", so the word comes from here. This card
                    // rendered the figure alone until 2026-08-14; the comment that
                    // used to sit here claimed the server had already added it.
                    if let price = StartingPrice.label(offering.priceFromLabel) {
                        Text(price)
                            .font(BrandFont.display(17, .bold))
                            .foregroundStyle(BrandColor.accent)
                    }
                    Text("\(bookedDuration) min")
                        .font(BrandFont.mono(11)).foregroundStyle(BrandColor.textMuted)
                }
            }
            .padding(14)

            Divider().overlay(BrandColor.textPrimary.opacity(0.1))

            VStack(spacing: 9) {
                // ⚠️ The APPOINTMENT's zone, never the device's — see
                // `appointmentTimeZone`.
                successSummaryRow(
                    "WHEN", Wire.dateTime(scheduledFor, timeZone: appointmentTimeZone)
                )
                if let place = successPlaceLabel {
                    // Tap the address to open it in Maps. `ClientAddress.mapsURL`
                    // is the same helper the saved-address list uses, and mirrors
                    // the web page's `mapsHref`; nil when there's nothing to
                    // locate (in-salon, or an address with no text or pin), in
                    // which case the row stays plain text.
                    if let url = successPlaceURL {
                        Link(destination: url) {
                            successSummaryRow("WHERE", place, isLink: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        successSummaryRow("WHERE", place)
                    }
                }
            }
            .padding(14)
        }
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(BrandColor.textPrimary.opacity(0.12), lineWidth: 1)
        )
    }

    private func successSummaryRow(_ label: String, _ value: String,
                                   isLink: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(label)
                .font(BrandFont.mono(10)).tracking(1.2)
                .foregroundStyle(BrandColor.textMuted)
            Spacer(minLength: 8)
            Text(value)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(isLink ? BrandColor.accent : BrandColor.textPrimary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
            if isLink {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12))
                    .foregroundStyle(BrandColor.accent)
                    .accessibilityHidden(true)
            }
        }
        // The whole row is the tap target, so it clears 44pt even when the
        // address wraps to a single short line.
        .contentShape(Rectangle())
        .frame(minHeight: isLink ? 30 : 0)
    }

    /// The service address this booking is going to, when it has one. Only a
    /// MOBILE booking does — an in-salon booking's address belongs to the pro's
    /// location, which this flow does not carry.
    private var successAddress: ClientAddress? {
        guard isMobile else { return nil }
        return addresses.first { $0.id == selectedAddressId }
    }

    /// "In salon · <address>" / "Mobile · <street address>" — whichever this
    /// booking is, and in BOTH cases the address itself, not just the mode.
    ///
    /// 🔴 Tori's rule: every address is a maps link, and a booking has two
    /// possible addresses belonging to different people — an in-salon booking
    /// goes to the PRO's location, a mobile one to the CLIENT's. This row said a
    /// bare "In salon" for the salon case until 2026-08-14: a client who had
    /// just booked could not see, let alone navigate to, where they were going.
    ///
    /// Deliberately NOT the client address's `displayLine`: that prefers the
    /// saved LABEL ("Home"), which is the right shorthand in a picker where the
    /// client is choosing between their own saved places, and the wrong thing on
    /// a confirmation, which has to state where the pro is actually going. Same
    /// reason the salon side prefers `addressLine` over the salon's NAME.
    private var successPlaceLabel: String? {
        guard isMobile else {
            guard let address = salonAddressLine else { return "In salon" }
            return "In salon · \(address)"
        }
        guard let address = successAddress else { return "Mobile" }
        return "Mobile · \(address.detailLine ?? address.displayLine)"
    }

    private var successPlaceURL: URL? {
        if isMobile { return successAddress?.mapsURL }
        return MapsLink.url(address: salonAddressLine)
    }

    private var successNextSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WHAT HAPPENS NEXT")
                .font(BrandFont.mono(10)).tracking(1.4)
                .foregroundStyle(BrandColor.textMuted)

            ForEach(Self.successSteps(proName: proName), id: \.text) { step in
                HStack(spacing: 12) {
                    Image(systemName: step.symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(BrandColor.accent)
                        .frame(width: 30, height: 30)
                        .background(BrandColor.accent.opacity(0.12))
                        .clipShape(Circle())
                    Text(step.text)
                        .font(BrandFont.body(13.5)).foregroundStyle(BrandColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(BrandColor.textPrimary.opacity(0.12), lineWidth: 1)
        )
    }

    /// Kept in lock-step with `COPY.bookingConfirmation` on the web. The pro's
    /// pronouns are unknown, so every line says "they".
    static func successSteps(proName: String) -> [(symbol: String, text: String)] {
        [
            ("clock", "\(proName) reviews within a few hours."),
            ("bell.badge", "We’ll notify you the moment they confirm."),
            ("checkmark.shield", "No charge until they confirm."),
        ]
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message).font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await loadBootstrap() } }
                .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.accent)
        }
        .padding(40)
    }

    // MARK: - Data

    private func close() {
        releaseHoldInBackground()
        dismiss()
    }

    private func loadBootstrap() async {
        phase = .loading
        if mode.isEmpty { mode = initialMode }
        // Every reload means the PLACEMENT changed (mode, or the address it's
        // measured from), so the times on screen belong to the old one. Without
        // this the grid keeps a full list — e.g. salon's 15-minute grid rendered
        // under Mobile, whose slots the hold would then refuse.
        slots = []
        await releaseCurrentHold()
        // MOBILE availability is computed against the CLIENT's address (the pro's
        // travel radius from it), so the address has to be resolved BEFORE the
        // request — without it the server refuses bootstrap AND day outright with
        // CLIENT_SERVICE_ADDRESS_REQUIRED. Mirrors web's `canFetch` gate.
        if isMobile {
            await loadAddresses()
            guard selectedAddressId != nil else {
                phase = .needsAddress
                return
            }
        }
        do {
            let boot = try await session.client.booking.bootstrap(
                professionalId: professionalId, serviceId: offering.serviceId,
                offeringId: offering.id,
                locationType: mode,
                clientAddressId: isMobile ? selectedAddressId : nil,
                mediaId: lookMediaId,
                startDate: initialStartDate,
                rescheduleBookingId: rescheduleBookingId
            )
            // Open on the preselected slot's day when the feed handed us one, else
            // the server's suggested first day.
            if let iso = preselectedSlot, let instant = Wire.date(iso) {
                selectedYMD = ymdString(instant, tz: boot.timeZone)
            } else {
                selectedYMD = boot.selectedDay?.date ?? boot.availableDays.first?.date
            }
            phase = .ready(boot)
            // Remembered for the success screen, which outlives `.ready(boot)`.
            appointmentTimeZone = boot.timeZone
            baseDurationState = boot.request.durationMinutes
            salonAddressLine = boot.bookableLocation()?.addressLine
            serviceArea = boot.serviceArea

            // bootstrap already carries the suggested day's slots — use them
            // rather than asking for the same day again on first paint.
            if let seeded = boot.selectedDay, seeded.date == selectedYMD {
                applySlots(seeded.slots, boot: boot)
                await applyPreselect(boot)
            } else {
                await loadSlots(boot)
            }
            await loadAddOns()
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load availability.")
        }
    }

    /// Add-ons apply to new bookings only (a reschedule keeps the original ones).
    /// Best-effort: a failure just means the second step has nothing to offer,
    /// never a blocked booking. The same call carries the pro's
    /// cancellation-policy disclosure (M15), which the add-ons step gates on.
    private func loadAddOns() async {
        guard !isReschedule else { return }
        let result = try? await session.client.booking.addOns(
            offeringId: offering.id, locationType: mode
        )
        addOns = result?.addOns ?? []
        cancellationPolicy = result?.cancellationPolicy
    }

    /// Pick a service address and re-ask availability against it — a different
    /// address is a different travel-radius answer, so the days and slots on
    /// screen are no longer the right ones for it.
    private func selectAddress(_ addressId: String) {
        guard selectedAddressId != addressId else { return }
        selectedAddressId = addressId
        Task { await loadBootstrap() }
    }

    /// Load the client's saved service addresses for a mobile booking, defaulting
    /// the selection to their default (or first) address.
    private func loadAddresses() async {
        guard addresses.isEmpty else { return }
        loadingAddresses = true
        defer { loadingAddresses = false }
        do {
            addresses = try await session.client.addresses.serviceAddresses()
            addressLoadFailed = false
        } catch {
            // A failed fetch is not an empty address book — saying "add one" to a
            // client who already has one would send them to make a duplicate.
            addresses = []
            addressLoadFailed = true
        }
        if selectedAddressId == nil {
            selectedAddressId = (addresses.first { $0.isDefault } ?? addresses.first)?.id
        }
    }

    private func loadSlots(_ boot: AvailabilityBootstrap) async {
        guard let date = selectedYMD else { return }
        loadingSlots = true
        slotError = nil
        do {
            let day = try await session.client.booking.day(
                professionalId: professionalId, serviceId: offering.serviceId,
                offeringId: offering.id, locationId: boot.request.locationId,
                date: date, locationType: mode,
                clientAddressId: isMobile ? selectedAddressId : nil,
                // Add-ons are chosen on the NEXT step, so this grid is sized for
                // the base service — same as the web drawer, whose hold is then
                // re-sized when an add-on is ticked.
                addOnIds: [],
                rescheduleBookingId: rescheduleBookingId
            )
            applySlots(day.slots, boot: boot)
        } catch let error as APIError {
            slots = []
            slotError = error.userMessage
        } catch {
            slots = []
            slotError = "Couldn’t load open times. Check your connection and try again."
        }
        loadingSlots = false
        await applyPreselect(boot)
    }

    /// Adopt a day's slots and open on a daypart that actually has times in it.
    private func applySlots(_ next: [String], boot: AvailabilityBootstrap) {
        slots = next
        let grouped = BookingSheetPresentation.groupSlotsByPeriod(next, timeZone: boot.timeZone)
        period = BookingSheetPresentation.firstNonEmptyPeriod(grouped, preferred: period)
    }

    /// One-time: land on the freed-up slot the openings feed sent us to, if it is
    /// still bookable on this day.
    ///
    /// This PLACES THE HOLD, because picking a time is what holding is on this
    /// screen — the client arrived from a "this slot just opened" push, and a
    /// slot that merely looked selected would be a lie about what is reserved.
    /// It is given back on dismiss like any other, and only ever fires once.
    private func applyPreselect(_ boot: AvailabilityBootstrap) async {
        guard !didApplyPreselect else { return }
        didApplyPreselect = true
        guard let pre = preselectedSlot, slots.contains(pre) else { return }
        await pickSlot(pre, boot: boot)
    }

    /// Reserve a slot. Any previous reservation is handed back first — the client
    /// only ever holds one time.
    private func pickSlot(_ slot: String, boot: AvailabilityBootstrap) async {
        guard !holding, !booking else { return }
        if slot == hold?.scheduledFor { return }
        if addressRequiredButMissing {
            bookError = "Add a service address for a mobile booking."
            return
        }

        bookError = nil
        holding = true
        defer { holding = false }

        await releaseCurrentHold()

        do {
            let created = try await session.client.booking.createHold(
                offeringId: offering.id, locationId: boot.request.locationId,
                scheduledFor: slot, locationType: mode,
                clientAddressId: isMobile ? selectedAddressId : nil,
                // Base-sized on purpose: the add-ons step re-sizes this hold as
                // each one is ticked (B1-A), which is where a widened window can
                // still be refused while the add-on can be un-ticked.
                addOnIds: [],
                rescheduleBookingId: rescheduleBookingId
            )
            hold = created
            holdExpiresAt = Wire.date(created.expiresAt)
            holdConsumed = false
        } catch let error as APIError {
            bookError = error.userMessage
        } catch {
            bookError = "Couldn’t hold that time. Try another slot."
        }
    }

    /// The CTA: a reschedule commits here, a new booking moves to the add-ons step.
    private func advance(_ boot: AvailabilityBootstrap) async {
        guard let hold, !booking, !holding else { return }

        if let holdExpiresAt, holdExpiresAt <= Date() {
            bookError = "That hold expired. Pick a new time."
            self.hold = nil
            self.holdExpiresAt = nil
            return
        }

        guard let rescheduleBookingId else {
            path.append(.addOns)
            return
        }

        booking = true
        bookError = nil
        defer { booking = false }

        do {
            // A reschedule commits the BOOKING's duration, not the offering's,
            // and the two drift whenever a duration is edited — the hold above
            // was already sized from the booking for that reason (B3).
            let result = try await session.client.booking.reschedule(
                bookingId: rescheduleBookingId, holdId: hold.id,
                locationType: mode
            )
            holdConsumed = true
            session.signalRefresh() // surface the change in Appointments/Home
            phase = .success(
                scheduledFor: result.scheduledFor, bookingId: nil, professionalId: nil
            )
        } catch let error as APIError {
            bookError = error.userMessage
        } catch {
            bookError = "Couldn’t reschedule. Try again."
        }
    }

    /// Hand the current reservation back and forget it. No-op once it has become
    /// a booking — releasing then would be cancelling the appointment.
    private func releaseCurrentHold() async {
        guard let id = hold?.id, !holdConsumed else {
            hold = nil
            holdExpiresAt = nil
            return
        }
        hold = nil
        holdExpiresAt = nil
        await session.client.booking.releaseHold(holdId: id)
    }

    /// Fire-and-forget release for teardown paths (dismiss / disappear), where
    /// there is no longer a view to await on.
    private func releaseHoldInBackground() {
        guard let id = hold?.id, !holdConsumed else { return }
        hold = nil
        holdExpiresAt = nil
        let bookingService = session.client.booking
        Task { await bookingService.releaseHold(holdId: id) }
    }

    // MARK: - Formatting

    private func timeZoneLabel(_ boot: AvailabilityBootstrap) -> String? {
        boot.timeZone.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
    }

    private func slotLabel(_ iso: String, tz: String) -> String {
        Wire.timeOnly(iso, timeZone: tz)
    }

    /// "MON" for a YYYY-MM-DD in the location's zone.
    private func dayWeekday(_ ymd: String, tz: String) -> String {
        guard let date = parseYMD(ymd, tz: tz) else { return "" }
        return formatted(date, tz: tz, pattern: "EEE").uppercased()
    }

    /// "06" for a YYYY-MM-DD in the location's zone.
    private func dayNumber(_ ymd: String, tz: String) -> String {
        guard let date = parseYMD(ymd, tz: tz) else { return "" }
        return formatted(date, tz: tz, pattern: "dd")
    }

    private func formatted(_ date: Date, tz: String, pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = TimeZone(identifier: tz)
        f.dateFormat = pattern
        return f.string(from: date)
    }

    private func ymdString(_ date: Date, tz: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: tz)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func parseYMD(_ string: String, tz: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: tz)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: string)
    }
}
