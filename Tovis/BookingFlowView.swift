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
    @State private var selectedSlot: String?
    @State private var booking = false
    @State private var bookError: String?

    // Add-ons (new bookings only — reschedule keeps the original add-ons).
    @State private var addOns: [BookingAddOn] = []
    @State private var selectedAddOnIds: Set<String> = []

    private var duration: Int { offering.durationMinutes ?? 60 }

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
                    .background(selectedSlot == nil ? BrandColor.textMuted.opacity(0.4) : BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(selectedSlot == nil || booking)
            }
            .padding(20)
        }
        .task { if slots.isEmpty { await loadSlots(boot) } }
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
        do {
            let boot = try await session.client.booking.bootstrap(
                professionalId: professionalId, serviceId: offering.serviceId,
                offeringId: offering.id, durationMinutes: duration,
                locationType: locationType
            )
            // Open on the server's suggested first day when present.
            if let first = boot.selectedDay?.date ?? boot.availableDays.first?.date,
               let d = ymd(first, tz: boot.timeZone) {
                selectedDate = d
            }
            phase = .ready(boot)
            await loadAddOns()
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
            offeringId: offering.id, locationType: locationType
        )) ?? []
    }

    private func loadSlots(_ boot: AvailabilityBootstrap) async {
        loadingSlots = true
        selectedSlot = nil
        let date = ymdString(selectedDate, tz: boot.timeZone)
        do {
            let day = try await session.client.booking.day(
                professionalId: professionalId, serviceId: offering.serviceId,
                offeringId: offering.id, locationId: boot.request.locationId,
                durationMinutes: duration, date: date, locationType: locationType
            )
            slots = day.slots
        } catch {
            slots = []
        }
        loadingSlots = false
    }

    private func requestToBook(_ boot: AvailabilityBootstrap) async {
        guard let slot = selectedSlot, !booking else { return }
        booking = true
        bookError = nil
        do {
            let hold = try await session.client.booking.createHold(
                offeringId: offering.id, locationId: boot.request.locationId,
                scheduledFor: slot, locationType: locationType
            )
            let scheduledFor: String
            if let rescheduleBookingId {
                let result = try await session.client.booking.reschedule(
                    bookingId: rescheduleBookingId, holdId: hold.id,
                    locationType: locationType, idempotencyKey: UUID().uuidString
                )
                scheduledFor = result.scheduledFor
            } else {
                let result = try await session.client.booking.finalize(
                    holdId: hold.id, offeringId: offering.id,
                    addOnIds: Array(selectedAddOnIds), idempotencyKey: UUID().uuidString
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