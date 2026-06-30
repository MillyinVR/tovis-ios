// Create a booking for a client — native port of web `app/pro/bookings/new`
// (NewBookingForm). Pick an existing client, a salon service, a salon location,
// a real open time slot, then create. POST /pro/bookings (idempotency-key); the
// options come from GET /pro/clients (directory), GET /pro/offerings, and
// GET /pro/locations.
//
// Time selection improves on the web's free `datetime-local` input: pick a date
// and the form fetches the pro's actual open slots for that service + location
// from GET /api/v1/availability/day (reused via BookingService.day) — the same
// availability the client booking flow uses. A "custom time" fallback keeps the
// free date/time entry + scheduling overrides for booking off-grid.
//
// The client is either an existing one (picked from the directory) or a new one
// created inline (first + last name + email, phone optional) — the server
// resolves either and sends a new client a secure claim invite.
//
// Scoped vs web: SALON bookings only (MOBILE needs the client service-address
// sub-flow).
import SwiftUI
import TovisKit

struct ProNewBookingView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    /// Called with the new booking id on success so the caller can refresh/open it.
    var onCreated: ((String) -> Void)?

    @State private var loading = true
    @State private var loadError: String?
    @State private var clients: [ProClientSummary] = []
    @State private var offerings: [ProOfferingAdmin] = []
    @State private var locations: [ProLocationSummary] = []
    /// The pro's own professionalId (availability is keyed by it).
    @State private var professionalId = ""

    @State private var clientMode: ClientMode = .existing
    @State private var clientId = ""
    @State private var newFirstName = ""
    @State private var newLastName = ""
    @State private var newEmail = ""
    @State private var newPhone = ""
    @State private var offeringId = ""
    @State private var locationId = ""

    private enum ClientMode: String, CaseIterable { case existing, new }

    // Slot-picker time selection (the shared ProOpenSlotPicker owns the date).
    @State private var selectedSlot: String?         // chosen ISO instant

    // Custom-time fallback.
    @State private var manualMode = false
    @State private var manualTime = Date().addingTimeInterval(3600)

    @State private var notes = ""
    @State private var showAdvanced = false
    @State private var allowOutsideWorkingHours = false
    @State private var allowShortNotice = false
    @State private var allowFarFuture = false

    @State private var creating = false
    @State private var errorText: String?

    private var hasTime: Bool { manualMode ? true : selectedSlot != nil }
    /// New client needs first + last name + email (server contract); phone optional.
    private var newClientReady: Bool {
        !trimmed(newFirstName).isEmpty && !trimmed(newLastName).isEmpty && !trimmed(newEmail).isEmpty
    }
    private var hasClient: Bool {
        clientMode == .existing ? !clientId.isEmpty : newClientReady
    }
    private var canCreate: Bool {
        !creating && hasClient && !offeringId.isEmpty && !locationId.isEmpty && hasTime
    }

    var body: some View {
        ScrollView {
            if loading {
                HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 80)
            } else if let loadError {
                Text(loadError).font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
                    .frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    clientSection
                    serviceSection
                    locationSection
                    timeSection
                    notesSection
                    advancedSection
                    if let errorText {
                        Text(errorText).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                    createButton
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("New booking")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .tint(BrandColor.accent)
        .task { await load() }
    }

    // MARK: - Sections

    private var clientSection: some View {
        BrandSection(title: "Client") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Client", selection: $clientMode.animation()) {
                    Text("Existing").tag(ClientMode.existing)
                    Text("New").tag(ClientMode.new)
                }
                .pickerStyle(.segmented)

                if clientMode == .existing {
                    if clients.isEmpty {
                        emptyHint("No clients yet. Add a new client instead.")
                    } else {
                        menu(selection: $clientId, options: clients.map { ($0.id, $0.fullName) },
                             placeholder: "Choose a client")
                    }
                } else {
                    newClientFields
                }
            }
        }
    }

    private var newClientFields: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                clientField("First name *", text: $newFirstName)
                clientField("Last name *", text: $newLastName)
            }
            clientField("Email *", text: $newEmail, keyboard: .emailAddress)
            clientField("Phone", text: $newPhone, keyboard: .phonePad)
            Text("We’ll send this client a secure claim invite.")
                .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func clientField(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(keyboard == .emailAddress ? .never : .words)
            .autocorrectionDisabled(keyboard == .emailAddress)
            .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 11)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(creating)
    }

    private var serviceSection: some View {
        BrandSection(title: "Service") {
            if salonOfferings.isEmpty {
                emptyHint("No salon services available. Add an in-salon offering first.")
            } else {
                menu(selection: $offeringId,
                     options: salonOfferings.map { ($0.id, offeringLabel($0)) },
                     placeholder: "Choose a service")
            }
        }
    }

    private var locationSection: some View {
        BrandSection(title: "Location") {
            if salonLocations.isEmpty {
                emptyHint("No bookable salon location. Add one in your locations.")
            } else {
                menu(selection: $locationId,
                     options: salonLocations.map { ($0.id, $0.name ?? $0.formattedAddress ?? "Location") },
                     placeholder: "Choose a location")
            }
        }
    }

    private var timeSection: some View {
        BrandSection(title: "Date & time") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $manualMode.animation()) {
                    Text("Enter a custom time").font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                .tint(BrandColor.accent)

                if manualMode {
                    BrandSurface {
                        DatePicker("", selection: $manualTime, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden().tint(BrandColor.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Off-grid times may need the scheduling overrides below.")
                        .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                } else if let offering = selectedOffering, let location = selectedLocation {
                    ProOpenSlotPicker(
                        professionalId: professionalId,
                        serviceId: offering.serviceId,
                        offeringId: offering.id,
                        locationId: location.id,
                        locationType: (location.type ?? "SALON").uppercased() == "MOBILE" ? "MOBILE" : "SALON",
                        locationTimeZone: location.timeZone,
                        durationMinutes: offering.salonDurationMinutes ?? 60,
                        selectedSlot: $selectedSlot,
                    )
                } else {
                    emptyHint("Choose a service to see open times.")
                }
            }
        }
    }

    private var notesSection: some View {
        BrandSection(title: "Internal notes") {
            BrandSurface {
                TextField("Optional — only you see these…", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
                    .font(BrandFont.body(14)).foregroundStyle(BrandColor.textPrimary)
            }
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation { showAdvanced.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                    Text("Scheduling overrides").font(BrandFont.body(13, .semibold))
                }
                .foregroundStyle(BrandColor.textSecondary)
            }
            if showAdvanced {
                BrandSurface {
                    VStack(spacing: 10) {
                        Toggle("Allow outside working hours", isOn: $allowOutsideWorkingHours)
                        Toggle("Allow short notice", isOn: $allowShortNotice)
                        Toggle("Allow far-future date", isOn: $allowFarFuture)
                    }
                    .font(BrandFont.body(13)).tint(BrandColor.accent)
                    .foregroundStyle(BrandColor.textPrimary)
                }
            }
        }
    }

    private var createButton: some View {
        Button { Task { await create() } } label: {
            HStack {
                if creating { ProgressView().tint(BrandColor.onAccent) }
                Text(creating ? "Creating…" : "Create booking").font(BrandFont.body(16, .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(canCreate ? BrandColor.accent : BrandColor.bgSecondary)
            .foregroundStyle(canCreate ? BrandColor.onAccent : BrandColor.textMuted)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(!canCreate)
    }

    // MARK: - Helpers

    private var salonOfferings: [ProOfferingAdmin] {
        offerings.filter { $0.isActive && $0.offersInSalon }
    }
    private var salonLocations: [ProLocationSummary] {
        locations.filter { $0.isBookable && ($0.type ?? "SALON").uppercased() != "MOBILE" }
    }
    private var selectedOffering: ProOfferingAdmin? {
        salonOfferings.first { $0.id == offeringId }
    }
    private var selectedLocation: ProLocationSummary? {
        salonLocations.first { $0.id == locationId }
    }

    private func offeringLabel(_ offering: ProOfferingAdmin) -> String {
        let price = offering.salonPriceStartingAt ?? offering.minPrice
        let priceSuffix = price.map { " · $\($0)" } ?? ""
        let duration = offering.salonDurationMinutes.map { " · \($0) min" } ?? ""
        return "\(offering.serviceName)\(priceSuffix)\(duration)"
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text).font(BrandFont.body(13)).foregroundStyle(BrandColor.textMuted)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A bordered menu picker over (id, label) options.
    private func menu(selection: Binding<String>, options: [(String, String)], placeholder: String) -> some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button(option.1) { selection.wrappedValue = option.0 }
            }
        } label: {
            HStack {
                Text(options.first(where: { $0.0 == selection.wrappedValue })?.1 ?? placeholder)
                    .font(BrandFont.body(15))
                    .foregroundStyle(selection.wrappedValue.isEmpty ? BrandColor.textMuted : BrandColor.textPrimary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12)).foregroundStyle(BrandColor.textMuted)
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.12), lineWidth: 1))
        }
    }

    // MARK: - Data

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            async let clientsTask = session.client.proClients.directory()
            async let offeringsTask = session.client.proProfile.offerings()
            async let locationsTask = session.client.proCalendar.locations()
            async let profileTask = session.client.proProfile.myProfile()
            clients = try await clientsTask.clients
            offerings = try await offeringsTask
            locations = try await locationsTask
            professionalId = try await profileTask.id
            // Default the location to the primary bookable one.
            locationId = salonLocations.first(where: { $0.isPrimary })?.id ?? salonLocations.first?.id ?? ""
        } catch let error as APIError {
            loadError = error.userMessage
        } catch {
            loadError = "Couldn’t load booking options."
        }
    }


    private func create() async {
        guard canCreate, let location = selectedLocation else { return }
        errorText = nil
        creating = true
        defer { creating = false }

        // Slot mode uses the chosen instant directly; custom mode formats the
        // free date/time.
        let scheduledISO: String
        if manualMode {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            scheduledISO = formatter.string(from: manualTime)
        } else if let slot = selectedSlot {
            scheduledISO = slot
        } else {
            return
        }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        // Existing client → clientId; new client → an inline client to create.
        let newClient: ProNewBookingClient? = clientMode == .new
            ? ProNewBookingClient(
                firstName: trimmed(newFirstName), lastName: trimmed(newLastName),
                email: trimmed(newEmail),
                phone: trimmed(newPhone).isEmpty ? nil : trimmed(newPhone),
            )
            : nil

        do {
            let newId = try await session.client.proBookings.createBooking(
                clientId: clientMode == .existing ? clientId : nil,
                client: newClient,
                offeringId: offeringId,
                locationId: locationId,
                locationType: (location.type ?? "SALON").uppercased() == "MOBILE" ? "MOBILE" : "SALON",
                scheduledFor: scheduledISO,
                internalNotes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                allowOutsideWorkingHours: allowOutsideWorkingHours,
                allowShortNotice: allowShortNotice,
                allowFarFuture: allowFarFuture,
            )
            session.signalRefresh()
            onCreated?(newId)
            dismiss()
        } catch let error as APIError {
            errorText = error.userMessage
        } catch {
            errorText = "Couldn’t create the booking. Check your connection and try again."
        }
    }
}
