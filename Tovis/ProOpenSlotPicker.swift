// A reusable open-appointment-slot picker — a date stepper + the pro's real
// available start times for a service + location, fetched from
// GET /api/v1/availability/day (via the shared BookingService.day). Used by the
// new-booking form and the aftercare "Next booking date" rebook mode. The
// binding holds the chosen ISO start instant (nil = nothing picked).
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
    let durationMinutes: Int
    /// For a MOBILE booking, the client's saved service-address id so slots respect
    /// the pro's travel radius. nil for SALON (or an as-yet-unsaved MOBILE address).
    var clientAddressId: String? = nil
    /// The chosen slot's ISO start instant.
    @Binding var selectedSlot: String?

    @State private var selectedDate = Date()
    @State private var slots: [String] = []
    @State private var slotTimeZone: String?
    @State private var loadingSlots = false
    @State private var slotError: String?

    /// The zone the availability `date` param is interpreted in. The picker is
    /// pinned to it so the day the pro taps is the day fetched — unpinned, a
    /// device zone straddling midnight against the location's fetches the
    /// neighboring day.
    private var dayZone: TimeZone { TimeZone(identifier: locationTimeZone ?? "") ?? .current }

    /// Re-fetch whenever the service/location/date inputs change.
    private var fetchKey: String {
        "\(professionalId)|\(serviceId)|\(offeringId)|\(locationId)|\(clientAddressId ?? "")|\(ymd(selectedDate))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandSurface {
                DatePicker("", selection: $selectedDate, in: Date()..., displayedComponents: [.date])
                    .labelsHidden().tint(BrandColor.accent)
                    .environment(\.timeZone, dayZone)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            slotGrid
        }
        .task(id: fetchKey) { await fetchSlots() }
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
            hint("No open times on this day. Try another date.")
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
                durationMinutes: durationMinutes,
                date: ymd(selectedDate),
                locationType: locationType,
                clientAddressId: clientAddressId,
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
