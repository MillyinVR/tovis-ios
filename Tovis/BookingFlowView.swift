// Booking flow (v1, request-to-book) — pick a date + time for an offering,
// optionally add add-ons, then hold + finalize. Opened as a sheet from the pro
// profile. Salon mode, no in-app payment (handled per the pro's settings / at
// appointment); Stripe checkout lands via the tovis:// deep-link return.
import SwiftUI
import TovisKit

struct BookingFlowView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let professionalId: String
    let proName: String
    let offering: ProOffering
    /// When set, this flow RESCHEDULES that booking (hold → reschedule) instead
    /// of creating a new one (hold → finalize). The picker is otherwise identical.
    var rescheduleBookingId: String? = nil
    /// The booking's location mode, preserved across a reschedule. Defaults to SALON.
    var locationType: String = "SALON"
    /// When set, the flow opens on this ISO instant's day and pre-selects it as the
    /// time slot when it's still bookable — used by the openings feed to land the
    /// client on the freed-up slot (mirrors the web `?scheduledFor=` deep-link).
    /// General availability drives the hold, so a slot that's no longer open simply
    /// isn't preselected and the client picks another time.
    var preselectedSlot: String? = nil

    private var isReschedule: Bool { rescheduleBookingId != nil }

    private enum Phase {
        case loading
        case ready(AvailabilityBootstrap)
        case failed(String)
        /// Carries the (re)scheduled instant ISO — works for finalize + reschedule.
        case success(String)
    }

    @State private var phase: Phase = .loading
    @State private var selectedDate = Date()
    @State private var slots: [String] = []
    @State private var loadingSlots = false
    /// Non-nil when the availability fetch itself failed (vs. a genuinely empty
    /// day) — surfaced with a retry instead of a misleading "no openings".
    @State private var slotError: String?
    @State private var selectedSlot: String?
    @State private var booking = false
    @State private var bookError: String?
    /// Guards the one-time preselect so a later date change / manual pick wins.
    @State private var didApplyPreselect = false

    // Add-ons (new bookings only — reschedule keeps the original add-ons).
    @State private var addOns: [BookingAddOn] = []
    @State private var selectedAddOnIds: Set<String> = []

    // Location mode (SALON / MOBILE). New bookings can choose when the offering
    // offers both; reschedule keeps the original. MOBILE needs a service address.
    @State private var mode = ""
    @State private var addresses: [ClientAddress] = []
    @State private var selectedAddressId: String?
    @State private var loadingAddresses = false
    @State private var showAddAddress = false

    private var duration: Int { offering.durationMinutes ?? 60 }

    private var isMobile: Bool { mode.uppercased() == "MOBILE" }

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

    /// Base duration + the minutes of every selected add-on (display only — the
    /// server is the source of truth and the hold isn't extended, matching web).
    private var totalDuration: Int {
        duration + addOns.filter { selectedAddOnIds.contains($0.id) }.reduce(0) { $0 + $1.minutes }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView().tint(BrandColor.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message):
                    failure(message)
                case let .success(scheduledFor):
                    success(scheduledFor)
                case let .ready(boot):
                    form(boot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle(isReschedule ? "Reschedule" : "Book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
            }
            .task { if case .loading = phase { await loadBootstrap() } }
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Form

    private func form(_ boot: AvailabilityBootstrap) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Offering summary
                BrandSurface {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(offering.name)
                            .font(BrandFont.body(17, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        Text("with \(proName)")
                            .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
                        HStack(spacing: 10) {
                            BrandPill(text: "\(totalDuration) min")
                            if let price = offering.priceFromLabel {
                                BrandPill(text: "from \(price)", tint: BrandColor.accent)
                            }
                        }
                        .padding(.top, 2)
                    }
                }

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

                if isMobile {
                    BrandSection(title: "Service address", trailing: "Required") {
                        addressSection
                    }
                }

                BrandSection(title: "Pick a date") {
                    DatePicker("", selection: $selectedDate, in: Date()...maxDate(boot),
                               displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .tint(BrandColor.accent)
                        .onChange(of: selectedDate) { Task { await loadSlots(boot) } }
                }

                BrandSection(title: "Pick a time", trailing: timeZoneLabel(boot)) {
                    if loadingSlots {
                        ProgressView().tint(BrandColor.accent).frame(maxWidth: .infinity).padding(.vertical, 20)
                    } else if let slotError {
                        // A failed fetch is not an empty day — say so, and offer a retry.
                        VStack(alignment: .leading, spacing: 8) {
                            Text(slotError)
                                .font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                            Button("Try again") { Task { await loadSlots(boot) } }
                                .font(BrandFont.body(13, .semibold)).tint(BrandColor.accent)
                        }
                        .padding(.vertical, 8)
                    } else if slots.isEmpty {
                        Text("No openings on this day. Try another date.")
                            .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                            .padding(.vertical, 8)
                    } else {
                        slotGrid(boot)
                    }
                }

                if !isReschedule && !addOns.isEmpty {
                    BrandSection(title: "Add-ons", trailing: "Optional") {
                        VStack(spacing: 10) {
                            ForEach(addOns) { addOn in
                                addOnRow(addOn)
                            }
                        }
                    }
                }

                if let bookError {
                    Text(bookError).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                }

                Button { Task { await requestToBook(boot) } } label: {
                    Group {
                        if booking { ProgressView().tint(BrandColor.onAccent) }
                        else {
                            Text(isReschedule ? "Confirm new time" : "Request to book")
                                .font(BrandFont.body(17, .semibold))
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .foregroundStyle(BrandColor.onAccent)
                    .background(bookDisabled ? BrandColor.textMuted.opacity(0.4) : BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(bookDisabled)
            }
            .padding(20)
        }
        .task { if slots.isEmpty { await loadSlots(boot) } }
        .sheet(isPresented: $showAddAddress) {
            AddServiceAddressSheet { newAddress in
                addresses.insert(newAddress, at: 0)
                selectedAddressId = newAddress.id
            }
        }
    }

    private var bookDisabled: Bool {
        selectedSlot == nil || booking || addressRequiredButMissing
    }

    // MARK: - Address picker (mobile)

    @ViewBuilder
    private var addressSection: some View {
        if loadingAddresses {
            ProgressView().tint(BrandColor.accent).frame(maxWidth: .infinity).padding(.vertical, 16)
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
        return Button { selectedAddressId = address.id } label: {
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

    private func slotGrid(_ boot: AvailabilityBootstrap) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(slots, id: \.self) { slot in
                let isSelected = slot == selectedSlot
                Button { selectedSlot = slot; bookError = nil } label: {
                    Text(slotLabel(slot, tz: boot.timeZone))
                        .font(BrandFont.body(14, .medium))
                        .foregroundStyle(isSelected ? BrandColor.onAccent : BrandColor.textPrimary)
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(isSelected ? BrandColor.accent : BrandColor.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(BrandColor.textMuted.opacity(isSelected ? 0 : 0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func addOnRow(_ addOn: BookingAddOn) -> some View {
        let isSelected = selectedAddOnIds.contains(addOn.id)
        return Button {
            if isSelected { selectedAddOnIds.remove(addOn.id) }
            else { selectedAddOnIds.insert(addOn.id) }
            bookError = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? BrandColor.accent : BrandColor.textMuted.opacity(0.5))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(addOn.title)
                            .font(BrandFont.body(15, .medium)).foregroundStyle(BrandColor.textPrimary)
                        if addOn.isRecommended {
                            BrandPill(text: "Popular", tint: BrandColor.accent)
                        }
                    }
                    Text("+\(addOn.minutes) min")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                }
                Spacer(minLength: 8)
                Text(priceLabel(addOn.price))
                    .font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textSecondary)
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

    private func success(_ scheduledFor: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(BrandColor.accent)
            Text(isReschedule ? "Time updated" : "Request sent")
                .font(BrandFont.display(24, .semibold)).foregroundStyle(BrandColor.textPrimary)
            Text("\(offering.name) with \(proName)")
                .font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
            Text(Wire.dateTime(scheduledFor, timeZone: nil))
                .font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
            Text(isReschedule
                 ? "Your appointment was moved. \(proName) will be notified."
                 : "\(proName) will confirm your booking. You’ll find it under Appointments.")
                .font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
            Button { dismiss() } label: {
                Text("Done").font(BrandFont.body(16, .semibold)).foregroundStyle(BrandColor.onAccent)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(BrandColor.accent).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.top, 8)
        }
        .padding(28)
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

    private func maxDate(_ boot: AvailabilityBootstrap) -> Date {
        Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date()
    }

    private func loadBootstrap() async {
        phase = .loading
        if mode.isEmpty { mode = initialMode }
        do {
            let boot = try await session.client.booking.bootstrap(
                professionalId: professionalId, serviceId: offering.serviceId,
                offeringId: offering.id, durationMinutes: duration,
                locationType: mode
            )
            // Open on the preselected slot's day when the feed handed us one, else
            // the server's suggested first day.
            if let iso = preselectedSlot, let instant = Wire.date(iso) {
                selectedDate = ymd(ymdString(instant, tz: boot.timeZone), tz: boot.timeZone) ?? selectedDate
            } else if let first = boot.selectedDay?.date ?? boot.availableDays.first?.date,
                      let d = ymd(first, tz: boot.timeZone) {
                selectedDate = d
            }
            phase = .ready(boot)
            await loadAddOns()
            if isMobile { await loadAddresses() }
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load availability.")
        }
    }

    /// Add-ons apply to new bookings only (a reschedule keeps the original ones).
    /// Best-effort: a failure just hides the section, never blocks booking.
    private func loadAddOns() async {
        guard !isReschedule else { return }
        addOns = (try? await session.client.booking.addOns(
            offeringId: offering.id, locationType: mode
        )) ?? []
    }

    /// Load the client's saved service addresses for a mobile booking, defaulting
    /// the selection to their default (or first) address.
    private func loadAddresses() async {
        guard addresses.isEmpty else { return }
        loadingAddresses = true
        defer { loadingAddresses = false }
        addresses = (try? await session.client.addresses.serviceAddresses()) ?? []
        if selectedAddressId == nil {
            selectedAddressId = (addresses.first { $0.isDefault } ?? addresses.first)?.id
        }
    }

    private func loadSlots(_ boot: AvailabilityBootstrap) async {
        loadingSlots = true
        slotError = nil
        selectedSlot = nil
        let date = ymdString(selectedDate, tz: boot.timeZone)
        do {
            let day = try await session.client.booking.day(
                professionalId: professionalId, serviceId: offering.serviceId,
                offeringId: offering.id, locationId: boot.request.locationId,
                durationMinutes: duration, date: date, locationType: mode
            )
            slots = day.slots
        } catch let error as APIError {
            slots = []
            slotError = error.userMessage
        } catch {
            slots = []
            slotError = "Couldn’t load open times. Check your connection and try again."
        }
        // One-time: land on the freed-up slot if it's still bookable on this day.
        if !didApplyPreselect {
            if let pre = preselectedSlot, slots.contains(pre) { selectedSlot = pre }
            didApplyPreselect = true
        }
        loadingSlots = false
    }

    private func requestToBook(_ boot: AvailabilityBootstrap) async {
        guard let slot = selectedSlot, !booking else { return }
        if addressRequiredButMissing {
            bookError = "Add a service address for a mobile booking."
            return
        }
        booking = true
        bookError = nil
        do {
            let hold = try await session.client.booking.createHold(
                offeringId: offering.id, locationId: boot.request.locationId,
                scheduledFor: slot, locationType: mode,
                clientAddressId: isMobile ? selectedAddressId : nil
            )
            let scheduledFor: String
            if let rescheduleBookingId {
                let result = try await session.client.booking.reschedule(
                    bookingId: rescheduleBookingId, holdId: hold.id,
                    locationType: mode
                )
                scheduledFor = result.scheduledFor
            } else {
                let result = try await session.client.booking.finalize(
                    holdId: hold.id, offeringId: offering.id, locationType: mode,
                    addOnIds: Array(selectedAddOnIds)
                )
                scheduledFor = result.scheduledFor
            }
            session.signalRefresh() // surface the change in Appointments/Home
            phase = .success(scheduledFor)
        } catch let error as APIError {
            bookError = error.userMessage
        } catch {
            bookError = isReschedule
                ? "Couldn’t reschedule. Try again."
                : "Couldn’t complete the booking. Try again."
        }
        booking = false
    }

    // MARK: - Formatting

    private func timeZoneLabel(_ boot: AvailabilityBootstrap) -> String? {
        boot.timeZone.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
    }

    /// Add-on prices arrive as a bare decimal string ("25.00"); render with a
    /// currency symbol and drop a trailing ".00" to match the offering pills.
    private func priceLabel(_ raw: String) -> String {
        let trimmed = raw.hasSuffix(".00") ? String(raw.dropLast(3)) : raw
        let hasSymbol = trimmed.first.map { !$0.isNumber } ?? false
        return hasSymbol ? trimmed : "$\(trimmed)"
    }

    private func slotLabel(_ iso: String, tz: String) -> String {
        guard let date = Wire.date(iso) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = TimeZone(identifier: tz)
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    private func ymdString(_ date: Date, tz: String) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: tz)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func ymd(_ string: String, tz: String) -> Date? {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: tz)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: string)
    }
}