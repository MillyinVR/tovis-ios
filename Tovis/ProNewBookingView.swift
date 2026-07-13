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
    /// When set (e.g. from tapping an empty calendar slot), the form opens in
    /// custom-time mode seeded to this instant so the pro can create right away.
    var prefillDate: Date?
    /// When set (e.g. offering a waitlist client a slot), the form opens with
    /// this existing client + offering pre-selected so the pro just picks a time.
    var prefillClientId: String?
    var prefillOfferingId: String?

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

    // SALON vs MOBILE (the pro's mobile base + the client's service address).
    @State private var bookingMode: BookingMode = .salon

    // MOBILE address: an existing saved client address OR a new one via Places.
    @State private var addressMode: AddressMode = .existing
    @State private var clientAddresses: [ProClientAddress] = []
    @State private var clientAddressesLoading = false
    @State private var clientAddressId = ""
    @State private var pickedPlace: PlaceDetails?
    @State private var newAddressLabel = ""
    @State private var newAddressApt = ""

    private enum ClientMode: String, CaseIterable { case existing, new }
    private enum BookingMode: String, CaseIterable { case salon, mobile }
    private enum AddressMode: String, CaseIterable { case existing, new }

    // Slot-picker time selection (the shared ProOpenSlotPicker owns the date).
    @State private var selectedSlot: String?         // chosen ISO instant

    // Custom-time fallback.
    @State private var manualMode = false
    @State private var manualTime = Date().addingTimeInterval(3600)

    // Passive double-book heads-up: the clients the picked time collides with
    // (empty when clear). Fetched from the pro calendar so it stays in lockstep
    // with the grid's own overlap signal. The server still allows a pro overlap
    // (PRO_AUTHORIZED_OVERLAP) — this only surfaces it before submit. Mirrors the
    // web NewBookingForm + the drag-reschedule confirm note (#104).
    @State private var overlapNames: [String] = []

    @State private var notes = ""
    @State private var showAdvanced = false
    @State private var allowOutsideWorkingHours = false
    @State private var allowShortNotice = false
    @State private var allowFarFuture = false

    @State private var creating = false
    @State private var errorText: String?

    // The idempotency key for the in-flight POST. The server contract is "same
    // key ⇒ same body": the key stays stable only across an *identical* network
    // re-send, and MUST be re-minted whenever the body changes — otherwise the
    // server 409s ("idempotency key already used with a different request body").
    // A confirmed override adds a flag (a different body), so `confirmOverride`
    // re-mints it; each distinct body still gets exactly one key, so a network
    // re-send of that body can't double-book.
    @State private var attemptKey: String?
    @State private var appliedOverrides: Set<BookingOverrideFlag> = []
    @State private var overridePrompt: BookingOverridePrompt?
    /// Optional free-text reason recorded on the override audit log.
    @State private var overrideReason = ""
    /// Set after booking a new/unclaimed client — shows the claim-invite
    /// confirmation with a shareable link before the screen dismisses.
    @State private var claimInvite: ClaimInvite?

    /// The one-time claim invite for a freshly booked unclaimed client. The
    /// server has already sent it (SMS/email); this lets the pro share it too.
    private struct ClaimInvite: Identifiable {
        let id = UUID()
        let token: String
        let clientName: String
        /// Web claim landing page (`/claim/{token}`) — matches the link the
        /// server delivers. Mirrors the app's other ShareLink origins.
        var url: URL? { URL(string: "https://www.tovis.app/claim/\(token)") }
    }

    private var hasTime: Bool { manualMode ? true : selectedSlot != nil }
    /// New client needs first + last name + email (server contract); phone optional.
    private var newClientReady: Bool {
        !trimmed(newFirstName).isEmpty && !trimmed(newLastName).isEmpty && !trimmed(newEmail).isEmpty
    }
    private var hasClient: Bool {
        clientMode == .existing ? !clientId.isEmpty : newClientReady
    }
    /// SALON needs no address; MOBILE needs a saved address (existing mode) or a
    /// resolved Places pin (new mode).
    private var mobileAddressReady: Bool {
        guard bookingMode == .mobile else { return true }
        return addressMode == .existing ? !clientAddressId.isEmpty : pickedPlace != nil
    }
    private var canCreate: Bool {
        !creating && hasClient && !offeringId.isEmpty && !locationId.isEmpty
            && hasTime && mobileAddressReady
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
                    modeSection
                    serviceSection
                    locationSection
                    if bookingMode == .mobile { addressSection }
                    timeSection
                    notesSection
                    advancedSection
                    if let errorText {
                        Text(errorText).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        // Pin the primary action in a bottom bar so it always clears the home
        // indicator (a scrolling CTA got tucked under the safe area) and is
        // reachable without scrolling to the end of a long form.
        .safeAreaInset(edge: .bottom) {
            if !loading && loadError == nil { createBar }
        }
        .navigationTitle("New booking")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .tint(BrandColor.accent)
        .task {
            await load()
            // Seed a tapped calendar slot into the custom-time picker.
            if let prefillDate {
                manualTime = prefillDate
                manualMode = true
            }
            // Seed an existing client + offering (e.g. offering a waitlist client
            // a slot) once the pickers' options are loaded.
            if let prefillClientId, clients.contains(where: { $0.id == prefillClientId }) {
                clientMode = .existing
                clientId = prefillClientId
            }
            if let prefillOfferingId, offerings.contains(where: { $0.id == prefillOfferingId }) {
                offeringId = prefillOfferingId
            }
        }
        .onChange(of: bookingMode) { _, _ in revalidateForMode() }
        .task(id: addressFetchKey) { await loadClientAddresses() }
        .task(id: overlapCheckKey) { await refreshOverlapWarning() }
        .alert("Confirm booking", isPresented: overrideAlertBinding, presenting: overridePrompt) { prompt in
            TextField(prompt.reasonPlaceholder, text: $overrideReason)
            Button("Book anyway") { Task { await confirmOverride(prompt) } }
            Button("Cancel", role: .cancel) { attemptKey = nil; overrideReason = "" }
        } message: { prompt in
            Text(prompt.question)
        }
        .sheet(item: $claimInvite, onDismiss: { dismiss() }) { invite in
            claimInviteSheet(invite)
        }
    }

    /// Post-create confirmation for a new/unclaimed client: the server already
    /// sent the claim invite; this reassures the pro and offers to share the
    /// link. Closing the sheet dismisses the whole form (via `onDismiss`).
    private func claimInviteSheet(_ invite: ClaimInvite) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(BrandColor.accent)
            Text("Booking created")
                .font(BrandFont.display(20, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("We’ve texted or emailed \(invite.clientName) a secure link to confirm and finish setting up their profile. You can share it yourself too.")
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            if let url = invite.url {
                ShareLink(item: url) {
                    Text("Share claim link")
                        .font(BrandFont.body(16, .semibold))
                        .foregroundStyle(BrandColor.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(BrandColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            Button { claimInvite = nil } label: {
                Text("Done")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .presentationDetents([.medium])
    }

    /// Display name for the just-booked client — the inline new-client name, or
    /// the picked existing client's name.
    private var createdClientName: String {
        if clientMode == .new {
            let name = "\(trimmed(newFirstName)) \(trimmed(newLastName))"
                .trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "your client" : name
        }
        return clients.first { $0.id == clientId }?.fullName ?? "your client"
    }

    /// Drives the override confirm alert off the optional `overridePrompt`.
    private var overrideAlertBinding: Binding<Bool> {
        Binding(get: { overridePrompt != nil }, set: { if !$0 { overridePrompt = nil } })
    }

    /// Re-fetch the chosen client's saved addresses whenever the MOBILE address
    /// picker could need them (mode/client changes).
    private var addressFetchKey: String {
        "\(bookingMode.rawValue)|\(clientMode.rawValue)|\(clientId)"
    }

    /// Re-run the double-book check whenever the proposed window moves — the time
    /// (slot or custom), the location it's scoped to, or the service duration.
    private var overlapCheckKey: String {
        let timePart = manualMode
            ? "m:\(manualTime.timeIntervalSince1970)"
            : "s:\(selectedSlot ?? "")"
        let duration = selectedOffering.map { durationMinutes($0) } ?? 0
        return "\(locationId)|\(timePart)|\(duration)"
    }

    /// The proposed booking's start instant: the chosen custom time, or the
    /// picked open slot parsed back to a `Date`. nil when no time is set yet.
    private var proposedStartDate: Date? {
        if manualMode { return manualTime }
        return selectedSlot.flatMap(Wire.date)
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

    private var modeSection: some View {
        BrandSection(title: "Booking type") {
            Picker("Booking type", selection: $bookingMode.animation()) {
                Text("In-salon").tag(BookingMode.salon)
                Text("Mobile").tag(BookingMode.mobile)
            }
            .pickerStyle(.segmented)
        }
    }

    private var serviceSection: some View {
        BrandSection(title: "Service") {
            if modeOfferings.isEmpty {
                emptyHint(bookingMode == .mobile
                    ? "No mobile services available. Enable mobile on an offering first."
                    : "No salon services available. Add an in-salon offering first.")
            } else {
                menu(selection: $offeringId,
                     options: modeOfferings.map { ($0.id, offeringLabel($0)) },
                     placeholder: "Choose a service")
            }
        }
    }

    private var locationSection: some View {
        BrandSection(title: bookingMode == .mobile ? "Mobile base" : "Location") {
            if modeLocations.isEmpty {
                emptyHint(bookingMode == .mobile
                    ? "No mobile base location. Add a mobile base in your locations."
                    : "No bookable salon location. Add one in your locations.")
            } else {
                menu(selection: $locationId,
                     options: modeLocations.map { ($0.id, $0.name ?? $0.formattedAddress ?? "Location") },
                     placeholder: "Choose a location")
            }
        }
    }

    private var addressSection: some View {
        BrandSection(title: "Service address") {
            VStack(alignment: .leading, spacing: 12) {
                if canUseSavedAddresses {
                    Picker("Address", selection: $addressMode.animation()) {
                        Text("Saved").tag(AddressMode.existing)
                        Text("New").tag(AddressMode.new)
                    }
                    .pickerStyle(.segmented)
                }

                if addressMode == .existing && canUseSavedAddresses {
                    if clientAddressesLoading {
                        HStack(spacing: 8) {
                            ProgressView().tint(BrandColor.accent)
                            Text("Loading addresses…").font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                    } else {
                        menu(selection: $clientAddressId,
                             options: clientAddresses.map { ($0.id, savedAddressLabel($0)) },
                             placeholder: "Choose a saved address")
                    }
                } else {
                    newAddressFields
                }
            }
        }
    }

    private var newAddressFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlacesAddressSearchField(picked: $pickedPlace, disabled: creating)
                .onChange(of: pickedPlace) { _, newValue in
                    if newValue == nil { newAddressApt = "" }
                }
            if pickedPlace != nil {
                clientField("Label (optional)", text: $newAddressLabel)
                clientField("Apt / suite (optional)", text: $newAddressApt)
            }
            Text(clientMode == .existing && !clientId.isEmpty && clientAddresses.isEmpty
                ? "This client has no saved address — search a new one."
                : "Search the address where you’ll perform this service.")
                .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func savedAddressLabel(_ address: ProClientAddress) -> String {
        let prefix = address.label.isEmpty ? "" : "\(address.label) · "
        let star = address.isDefault ? " ★" : ""
        return "\(prefix)\(address.formattedAddress)\(star)"
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
                        locationType: bookingMode == .mobile ? "MOBILE" : "SALON",
                        locationTimeZone: location.timeZone,
                        durationMinutes: durationMinutes(offering),
                        clientAddressId: slotClientAddressId,
                        selectedSlot: $selectedSlot,
                    )
                } else {
                    emptyHint("Choose a service to see open times.")
                }

                if !overlapNames.isEmpty { overlapWarning }
            }
        }
    }

    /// Soft amber note when the picked time collides with an existing booking —
    /// the pre-submit mirror of the calendar grid's overlap ring + the drag
    /// confirm's "overlaps {client}" note. Non-blocking; never disables Create.
    private var overlapWarning: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Schedule conflict")
                .font(BrandFont.body(11, .semibold))
                .foregroundStyle(BrandColor.amber)
            Text("This overlaps \(overlapNamesText). You can still book it.")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BrandColor.amber.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(BrandColor.amber.opacity(0.25), lineWidth: 1))
    }

    /// "Sam" / "Sam and Alex" / "Sam, Alex, and Jordan" — a plain-English join.
    private var overlapNamesText: String {
        switch overlapNames.count {
        case 0: return ""
        case 1: return overlapNames[0]
        case 2: return "\(overlapNames[0]) and \(overlapNames[1])"
        default:
            let head = overlapNames.dropLast().joined(separator: ", ")
            return "\(head), and \(overlapNames[overlapNames.count - 1])"
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

    /// The single next thing the pro must do before the form can submit, so a
    /// disabled "Create booking" reads as intentional (not a broken button).
    /// nil when the form is ready.
    private var missingRequirement: String? {
        if !hasClient {
            return clientMode == .existing
                ? "Choose a client to continue"
                : "Add the new client's name and email"
        }
        if offeringId.isEmpty { return "Choose a service to continue" }
        if locationId.isEmpty {
            return bookingMode == .mobile ? "Choose a mobile base" : "Choose a location"
        }
        if !mobileAddressReady { return "Add the service address" }
        if !hasTime { return "Pick a time to continue" }
        return nil
    }

    /// Bottom-pinned action bar (via `.safeAreaInset`): an optional "what's left"
    /// hint above the button, on a hairline-topped surface matching the tab bars.
    private var createBar: some View {
        VStack(spacing: 8) {
            if let missingRequirement, !creating {
                Text(missingRequirement)
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            createButton
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(
            BrandColor.bgPrimary
                .overlay(alignment: .top) {
                    Rectangle().fill(BrandColor.textMuted.opacity(0.12)).frame(height: 1)
                }
                .ignoresSafeArea(.container, edges: .bottom)
        )
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
        // Stays tappable while the form is incomplete (greyed, not disabled) so a
        // tap explains what's missing instead of feeling dead. Only a submit
        // in flight disables it, to block a double-submit.
        .disabled(creating)
    }

    // MARK: - Helpers

    /// Offerings bookable in the chosen mode (in-salon vs mobile).
    private var modeOfferings: [ProOfferingAdmin] {
        offerings.filter {
            $0.isActive && (bookingMode == .mobile ? $0.offersMobile : $0.offersInSalon)
        }
    }
    /// Locations valid for the chosen mode: SALON/SUITE for in-salon, MOBILE_BASE
    /// for mobile.
    private var modeLocations: [ProLocationSummary] {
        locations.filter {
            guard $0.isBookable else { return false }
            let isMobileBase = ($0.type ?? "").uppercased() == "MOBILE_BASE"
            return bookingMode == .mobile ? isMobileBase : !isMobileBase
        }
    }
    private var selectedOffering: ProOfferingAdmin? {
        modeOfferings.first { $0.id == offeringId }
    }
    private var selectedLocation: ProLocationSummary? {
        modeLocations.first { $0.id == locationId }
    }
    /// The duration to schedule against for the chosen mode.
    private func durationMinutes(_ offering: ProOfferingAdmin) -> Int {
        (bookingMode == .mobile ? offering.mobileDurationMinutes : offering.salonDurationMinutes) ?? 60
    }
    /// MOBILE slots respect travel radius only for a saved address; a new
    /// (unsaved) address has no id yet, so slots fall back to the mobile base.
    private var slotClientAddressId: String? {
        guard bookingMode == .mobile, addressMode == .existing, !clientAddressId.isEmpty else { return nil }
        return clientAddressId
    }
    /// Existing-address picker is only offered for an existing client who has
    /// saved service addresses.
    private var canUseSavedAddresses: Bool {
        clientMode == .existing && !clientId.isEmpty && !clientAddresses.isEmpty
    }

    private func offeringLabel(_ offering: ProOfferingAdmin) -> String {
        let price = bookingMode == .mobile
            ? (offering.mobilePriceStartingAt ?? offering.minPrice)
            : (offering.salonPriceStartingAt ?? offering.minPrice)
        let priceSuffix = price.map { " · $\($0)" } ?? ""
        let duration = (bookingMode == .mobile ? offering.mobileDurationMinutes : offering.salonDurationMinutes)
            .map { " · \($0) min" } ?? ""
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
            // Default the location to the primary bookable one for the mode.
            locationId = defaultLocationId()
        } catch let error as APIError {
            loadError = error.userMessage
        } catch {
            loadError = "Couldn’t load booking options."
        }
    }

    private func defaultLocationId() -> String {
        modeLocations.first(where: { $0.isPrimary })?.id ?? modeLocations.first?.id ?? ""
    }

    /// Switching SALON↔MOBILE invalidates any selection that doesn't support the
    /// new mode (offerings/locations differ; the slot picker re-fetches on its own).
    private func revalidateForMode() {
        if selectedOffering == nil { offeringId = "" }
        if selectedLocation == nil { locationId = defaultLocationId() }
        selectedSlot = nil
    }

    /// Load the chosen existing client's saved service addresses (MOBILE only) and
    /// default the address mode + selection like the web form.
    private func loadClientAddresses() async {
        guard bookingMode == .mobile, clientMode == .existing, !clientId.isEmpty else {
            clientAddresses = []
            clientAddressId = ""
            addressMode = .new
            return
        }
        clientAddressesLoading = true
        defer { clientAddressesLoading = false }
        do {
            let addresses = try await session.client.proClients.serviceAddresses(clientId: clientId)
            clientAddresses = addresses
            if addresses.isEmpty {
                addressMode = .new
                clientAddressId = ""
            } else {
                addressMode = .existing
                clientAddressId = addresses.first(where: { $0.isDefault })?.id ?? addresses.first?.id ?? ""
            }
        } catch {
            // Non-fatal: fall back to entering a new address.
            clientAddresses = []
            clientAddressId = ""
            addressMode = .new
        }
    }

    /// Fetch the pro's bookings around the proposed time and surface the clients
    /// it collides with. Debounced (a superseding key cancels the task, which
    /// aborts the sleep); a background failure never errors the form — it just
    /// clears the note. BLOCK events are dropped so this only warns on
    /// client-vs-client double-books, matching the calendar confirm note.
    private func refreshOverlapWarning() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }

        guard let location = selectedLocation,
              let offering = selectedOffering,
              let start = proposedStartDate else {
            overlapNames = []
            return
        }

        let duration = max(15, durationMinutes(offering))
        let end = start.addingTimeInterval(Double(duration) * 60)

        // A generous ±1-day fetch window comfortably covers the longest possible
        // appointment; the half-open overlap check does the precise filtering.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let from = iso.string(from: start.addingTimeInterval(-86_400))
        let to = iso.string(from: start.addingTimeInterval(86_400))

        do {
            let response = try await session.client.proCalendar.calendar(
                from: from, to: to, locationId: location.id)
            if Task.isCancelled { return }

            let events: [(id: String, clientName: String, start: Date, end: Date)] =
                response.events.compactMap { event in
                    guard event.isBooking, let s = Wire.date(event.startsAt) else { return nil }
                    let e = Wire.date(event.endsAt)
                        ?? s.addingTimeInterval(Double(max(15, event.durationMinutes)) * 60)
                    return (event.id, event.clientName, s, e)
                }

            overlapNames = ProCalendarGrid.overlappingClientNames(
                proposedStart: start, proposedEnd: end,
                events: events, fallbackName: "another appointment")
        } catch {
            overlapNames = []
        }
    }


    /// Start a fresh create attempt: mint one idempotency key (stable across an
    /// override retry) and clear any override flags carried from a prior attempt.
    private func create() async {
        guard !creating else { return }
        // Incomplete form: don't dead-end — tell the pro exactly what's left.
        guard canCreate, selectedLocation != nil else {
            errorText = missingRequirement ?? "Choose a location to continue"
            return
        }
        appliedOverrides = []
        overrideReason = ""
        attemptKey = UUID().uuidString
        await submitBooking()
    }

    /// The pro confirmed an override-gated prompt — apply the flag and re-submit.
    /// Confirming adds an override flag, so the request body changes; mint a fresh
    /// idempotency key so the server sees a new logical request instead of 409ing
    /// on "same key, different body". (The prior key's record is already released
    /// server-side by the override rejection.)
    private func confirmOverride(_ prompt: BookingOverridePrompt) async {
        appliedOverrides.insert(prompt.flag)
        attemptKey = UUID().uuidString
        await submitBooking()
    }

    /// POST the booking for the current attempt. On an override-gated rejection
    /// (short notice / far future / outside hours) it surfaces a confirm prompt
    /// and, on approval, retries with the flag instead of dead-ending — matching
    /// the web NewBookingForm.
    private func submitBooking() async {
        guard let key = attemptKey, canCreate, selectedLocation != nil else { return }
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

        // MOBILE → either a saved client address id or a new (Places-resolved)
        // service address. SALON sends neither.
        let useExistingAddress = bookingMode == .mobile && addressMode == .existing && !clientAddressId.isEmpty
        let serviceAddress: ProServiceAddressInput? =
            (bookingMode == .mobile && addressMode == .new) ? buildServiceAddress() : nil

        // The manual "Scheduling overrides" toggles PLUS any flag the pro just
        // confirmed via the prompt.
        let outsideHours = allowOutsideWorkingHours || appliedOverrides.contains(.allowOutsideWorkingHours)
        let shortNotice = allowShortNotice || appliedOverrides.contains(.allowShortNotice)
        let farFuture = allowFarFuture || appliedOverrides.contains(.allowFarFuture)

        do {
            let result = try await session.client.proBookings.createBooking(
                clientId: clientMode == .existing ? clientId : nil,
                client: newClient,
                offeringId: offeringId,
                locationId: locationId,
                locationType: bookingMode == .mobile ? "MOBILE" : "SALON",
                scheduledFor: scheduledISO,
                clientAddressId: useExistingAddress ? clientAddressId : nil,
                serviceAddress: serviceAddress,
                internalNotes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                allowOutsideWorkingHours: outsideHours,
                allowShortNotice: shortNotice,
                allowFarFuture: farFuture,
                overrideReason: appliedOverrides.isEmpty || trimmed(overrideReason).isEmpty
                    ? nil : trimmed(overrideReason),
                idempotencyKey: key,
            )
            attemptKey = nil
            session.signalRefresh()
            onCreated?(result.bookingId)
            // A new/unclaimed client got a claim invite — confirm + let the pro
            // share the link before dismissing. Everyone else pops straight back.
            if result.invitedUnclaimedClient, let token = result.inviteToken {
                claimInvite = ClaimInvite(token: token, clientName: createdClientName)
            } else {
                dismiss()
            }
        } catch let error as APIError {
            // Override-gated? Offer a "book anyway?" retry (unless we already
            // applied that flag — then it's a genuine failure, don't loop).
            if let prompt = error.bookingOverridePrompt(intent: .create),
               !appliedOverrides.contains(prompt.flag) {
                overridePrompt = prompt
            } else {
                attemptKey = nil
                errorText = error.userMessage
            }
        } catch {
            attemptKey = nil
            errorText = "Couldn’t create the booking. Check your connection and try again."
        }
    }

    /// Build the inline MOBILE service address from the resolved Places pin
    /// (placeId + exact lat/lng → no server re-geocode) + optional label/apt.
    /// Mirrors `AddServiceAddressSheet`'s Places-resolved payload.
    private func buildServiceAddress() -> ProServiceAddressInput? {
        guard let place = pickedPlace else { return nil }
        return ProServiceAddressInput(
            label: trimmed(newAddressLabel).isEmpty ? nil : trimmed(newAddressLabel),
            formattedAddress: place.formattedAddress,
            addressLine2: trimmed(newAddressApt).isEmpty ? nil : trimmed(newAddressApt),
            city: place.city,
            state: place.state,
            postalCode: place.postalCode,
            countryCode: place.countryCode ?? "US",
            placeId: place.placeId,
            lat: place.lat,
            lng: place.lng,
        )
    }
}
