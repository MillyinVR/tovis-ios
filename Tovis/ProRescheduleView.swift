// Reschedule a booking to a new time — native port of the web calendar's pro
// reschedule (the BookingModal / drag-to-move on `/pro/calendar`). Reached from a
// "Reschedule" action on ProBookingDetailView while the booking is PENDING or
// ACCEPTED (not yet started, not terminal).
//
// The pro reschedule is a DIRECT time move: PATCH /pro/bookings/{id} with a new
// `scheduledFor` (via ProBookingService.reschedule) — it keeps the booking's
// existing services + location and creates NO hold. (That's the client-only
// `POST /bookings/{id}/reschedule` flow.) Time selection mirrors ProNewBookingView:
// pick a real open slot for the booking's service + location (ProOpenSlotPicker,
// off GET /availability/day), or flip to a custom time seeded to the current one.
// Off-grid times trip the scheduling guards; the same override "save it anyway?"
// retry as new-booking (intent `.edit`) re-submits with the authorizing flag.
import SwiftUI
import TovisKit

struct ProRescheduleView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let booking: ProBookingDetail

    /// The pro's own professionalId (availability is keyed by it); resolved on load.
    @State private var professionalId = ""
    @State private var loading = true

    // Slot-picker time selection (ProOpenSlotPicker owns the date); the custom-time
    // fallback is seeded to the booking's current start.
    @State private var selectedSlot: String?
    @State private var manualMode = false
    @State private var manualTime = Date().addingTimeInterval(3600)

    @State private var notifyClient = true

    @State private var showAdvanced = false
    @State private var allowOutsideWorkingHours = false
    @State private var allowShortNotice = false
    @State private var allowFarFuture = false

    @State private var submitting = false
    @State private var errorText: String?

    // Same idempotency contract as ProNewBookingView: one key per logical request,
    // re-minted whenever the body changes (a confirmed override adds a flag), so a
    // pure network re-send replays instead of moving the booking twice.
    @State private var attemptKey: String?
    @State private var appliedOverrides: Set<BookingOverrideFlag> = []
    @State private var overridePrompt: BookingOverridePrompt?
    /// Optional free-text reason recorded on the override audit log.
    @State private var overrideReason = ""

    // MARK: - Derived

    private var serviceId: String? { booking.baseItem?.serviceId }
    private var offeringId: String? { booking.baseItem?.offeringId }
    private var locationId: String? { booking.locationId }
    /// Open-slot suggestions need the base service, its offering, and a location.
    /// Without them (e.g. an offering-less legacy booking) we fall back to a custom
    /// time only.
    private var canUseSlotPicker: Bool {
        serviceId != nil && offeringId != nil && locationId != nil && !professionalId.isEmpty
    }
    /// Find slots that fit the whole appointment (base + add-ons), not just the base.
    private var slotDurationMinutes: Int {
        booking.totalDurationMinutes > 0 ? booking.totalDurationMinutes : booking.durationMinutes
    }
    private var hasTime: Bool { manualMode ? true : selectedSlot != nil }

    var body: some View {
        ScrollView {
            if loading {
                HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }.padding(.top, 80)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    contextSection
                    timeSection
                    notifySection
                    advancedSection
                    if let errorText {
                        Text(errorText).font(BrandFont.body(13)).foregroundStyle(BrandColor.ember)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            if !loading { saveBar }
        }
        .navigationTitle("Reschedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }.tint(BrandColor.accent)
            }
        }
        .tint(BrandColor.accent)
        .task { await load() }
        .alert("Confirm reschedule", isPresented: overrideAlertBinding, presenting: overridePrompt) { prompt in
            TextField(prompt.reasonPlaceholder, text: $overrideReason)
            Button("Save anyway") { Task { await confirmOverride(prompt) } }
            Button("Cancel", role: .cancel) { attemptKey = nil; overrideReason = "" }
        } message: { prompt in
            Text(prompt.question)
        }
    }

    // MARK: - Sections

    private var contextSection: some View {
        BrandSection(title: "Rescheduling") {
            VStack(alignment: .leading, spacing: 6) {
                Text(booking.title)
                    .font(BrandFont.body(15, .semibold)).foregroundStyle(BrandColor.textPrimary)
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(BrandColor.textMuted)
                    Text("Now: \(Wire.dateTime(booking.scheduledFor, timeZone: booking.timeZone))")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                }
                if !booking.client.fullName.isEmpty {
                    Text("for \(booking.client.fullName)")
                        .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                }
            }
        }
    }

    private var timeSection: some View {
        BrandSection(title: "New date & time") {
            VStack(alignment: .leading, spacing: 12) {
                if canUseSlotPicker {
                    Toggle(isOn: $manualMode.animation()) {
                        Text("Enter a custom time").font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                    .tint(BrandColor.accent)
                }

                if manualMode || !canUseSlotPicker {
                    BrandSurface {
                        DatePicker("", selection: $manualTime, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden().tint(BrandColor.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Off-grid times may need the scheduling overrides below.")
                        .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                } else if let serviceId, let offeringId, let locationId {
                    ProOpenSlotPicker(
                        professionalId: professionalId,
                        serviceId: serviceId,
                        offeringId: offeringId,
                        locationId: locationId,
                        locationType: booking.locationType,
                        locationTimeZone: booking.timeZone,
                        durationMinutes: slotDurationMinutes,
                        selectedSlot: $selectedSlot,
                    )
                }
            }
        }
    }

    private var notifySection: some View {
        BrandSection(title: "Notify client") {
            Toggle(isOn: $notifyClient) {
                Text("Text or email the client about the new time")
                    .font(BrandFont.body(13)).foregroundStyle(BrandColor.textSecondary)
            }
            .tint(BrandColor.accent)
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

    // MARK: - Save bar

    /// Bottom-pinned action bar (via `.safeAreaInset`) matching ProNewBookingView.
    private var saveBar: some View {
        VStack(spacing: 8) {
            if !hasTime && !submitting {
                Text("Pick a new time to continue")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            saveButton
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

    private var saveButton: some View {
        Button { Task { await reschedule() } } label: {
            HStack {
                if submitting { ProgressView().tint(BrandColor.onAccent) }
                Text(submitting ? "Rescheduling…" : "Reschedule").font(BrandFont.body(16, .semibold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(hasTime ? BrandColor.accent : BrandColor.bgSecondary)
            .foregroundStyle(hasTime ? BrandColor.onAccent : BrandColor.textMuted)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        // Greyed (not disabled) while incomplete so a tap explains what's missing;
        // only a submit in flight disables it, to block a double-move.
        .disabled(submitting)
    }

    /// Drives the override confirm alert off the optional `overridePrompt`.
    private var overrideAlertBinding: Binding<Bool> {
        Binding(get: { overridePrompt != nil }, set: { if !$0 { overridePrompt = nil } })
    }

    // MARK: - Data

    private func load() async {
        loading = true
        defer { loading = false }
        // Seed the custom-time picker to the booking's current start.
        manualTime = Wire.date(booking.scheduledFor) ?? manualTime
        // Slots need the pro's professionalId; if it can't be resolved, fall back to
        // a custom time rather than dead-ending the reschedule.
        do {
            professionalId = try await session.client.proProfile.myProfile().id
        } catch {
            professionalId = ""
        }
        if !canUseSlotPicker { manualMode = true }
    }

    // MARK: - Submit

    /// Start a fresh reschedule attempt: mint one idempotency key and clear any
    /// override flags carried from a prior attempt.
    private func reschedule() async {
        guard !submitting else { return }
        guard hasTime else {
            errorText = "Pick a new time to continue"
            return
        }
        appliedOverrides = []
        overrideReason = ""
        attemptKey = UUID().uuidString
        await submit()
    }

    /// The pro confirmed an override-gated prompt — apply the flag and re-submit
    /// with a fresh idempotency key (the changed body needs a new logical request).
    private func confirmOverride(_ prompt: BookingOverridePrompt) async {
        appliedOverrides.insert(prompt.flag)
        attemptKey = UUID().uuidString
        await submit()
    }

    /// PATCH the new time for the current attempt. On an override-gated rejection
    /// (short notice / far future / outside hours) it surfaces a confirm prompt and,
    /// on approval, retries with the flag instead of dead-ending — mirroring the web
    /// calendar reschedule (intent `.edit`).
    private func submit() async {
        guard let key = attemptKey, hasTime else { return }
        errorText = nil
        submitting = true
        defer { submitting = false }

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

        // The manual "Scheduling overrides" toggles PLUS any flag the pro just
        // confirmed via the prompt.
        let outsideHours = allowOutsideWorkingHours || appliedOverrides.contains(.allowOutsideWorkingHours)
        let shortNotice = allowShortNotice || appliedOverrides.contains(.allowShortNotice)
        let farFuture = allowFarFuture || appliedOverrides.contains(.allowFarFuture)

        do {
            try await session.client.proBookings.reschedule(
                bookingId: booking.id,
                scheduledFor: scheduledISO,
                notifyClient: notifyClient,
                allowOutsideWorkingHours: outsideHours,
                allowShortNotice: shortNotice,
                allowFarFuture: farFuture,
                overrideReason: appliedOverrides.isEmpty || overrideReason.trimmed.isEmpty
                    ? nil : overrideReason.trimmed,
                idempotencyKey: key,
            )
            attemptKey = nil
            session.signalRefresh()
            dismiss()
        } catch let error as APIError {
            // Override-gated? Offer a "save it anyway?" retry (unless we already
            // applied that flag — then it's a genuine failure, don't loop).
            if let prompt = error.bookingOverridePrompt(intent: .edit),
               !appliedOverrides.contains(prompt.flag) {
                overridePrompt = prompt
            } else {
                attemptKey = nil
                errorText = error.userMessage
            }
        } catch {
            attemptKey = nil
            errorText = "Couldn’t reschedule the booking. Check your connection and try again."
        }
    }
}
