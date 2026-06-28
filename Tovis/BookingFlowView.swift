// Booking flow (v1, request-to-book) — pick a date + time for an offering, then
// hold + finalize. Opened as a sheet from the pro profile. Salon mode, no
// add-ons, no in-app payment (handled per the pro's settings / at appointment);
// Stripe checkout lands once Universal-Link deep links exist.
import SwiftUI
import TovisKit

struct BookingFlowView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let professionalId: String
    let proName: String
    let offering: ProOffering

    private enum Phase {
        case loading
        case ready(AvailabilityBootstrap)
        case failed(String)
        case success(FinalizedBooking)
    }

    @State private var phase: Phase = .loading
    @State private var selectedDate = Date()
    @State private var slots: [String] = []
    @State private var loadingSlots = false
    @State private var selectedSlot: String?
    @State private var booking = false
    @State private var bookError: String?

    private var duration: Int { offering.durationMinutes ?? 60 }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView().tint(BrandColor.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .failed(message):
                    failure(message)
                case let .success(b):
                    success(b)
                case let .ready(boot):
                    form(boot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Book")
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
                            BrandPill(text: "\(duration) min")
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

                if let bookError {
                    Text(bookError).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                }

                Button { Task { await requestToBook(boot) } } label: {
                    Group {
                        if booking { ProgressView().tint(BrandColor.onAccent) }
                        else { Text("Request to book").font(BrandFont.body(17, .semibold)) }
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

    // MARK: - Success / failure

    private func success(_ b: FinalizedBooking) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(BrandColor.accent)
            Text("Request sent")
                .font(BrandFont.display(24, .semibold)).foregroundStyle(BrandColor.textPrimary)
            Text("\(offering.name) with \(proName)")
                .font(BrandFont.body(15)).foregroundStyle(BrandColor.textSecondary)
            Text(Wire.dateTime(b.scheduledFor, timeZone: nil))
                .font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
            Text("\(proName) will confirm your booking. You’ll find it under Appointments.")
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
                offeringId: offering.id, durationMinutes: duration
            )
            // Open on the server's suggested first day when present.
            if let first = boot.selectedDay?.date ?? boot.availableDays.first?.date,
               let d = ymd(first, tz: boot.timeZone) {
                selectedDate = d
            }
            phase = .ready(boot)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load availability.")
        }
    }

    private func loadSlots(_ boot: AvailabilityBootstrap) async {
        loadingSlots = true
        selectedSlot = nil
        let date = ymdString(selectedDate, tz: boot.timeZone)
        do {
            let day = try await session.client.booking.day(
                professionalId: professionalId, serviceId: offering.serviceId,
                offeringId: offering.id, locationId: boot.request.locationId,
                durationMinutes: duration, date: date
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
                offeringId: offering.id, locationId: boot.request.locationId, scheduledFor: slot
            )
            let result = try await session.client.booking.finalize(
                holdId: hold.id, offeringId: offering.id, idempotencyKey: UUID().uuidString
            )
            session.signalRefresh() // surface the new booking in Appointments/Home
            phase = .success(result)
        } catch let error as APIError {
            bookError = error.userMessage
        } catch {
            bookError = "Couldn’t complete the booking. Try again."
        }
        booking = false
    }

    // MARK: - Formatting

    private func timeZoneLabel(_ boot: AvailabilityBootstrap) -> String? {
        boot.timeZone.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
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