// Offer-a-time sheet for the pro waitlist workspace — the native port of the web
// `WaitlistOfferModal` (`app/pro/calendar/_components/WaitlistOfferModal.tsx`).
// Proposes a concrete appointment time — in-salon OR mobile — to a waitlisted
// client: pick a slot from the pro's live availability, then
// POST /api/v1/pro/waitlist/{entryId}/offer. The route creates a PENDING offer
// and notifies the client, who Confirms/Declines before it books.
//
// The mode list is NOT decided here. This sheet used to resolve its own context
// (bookable SALON/SUITE from `proCalendar.locations()`, offering from
// `proBookings.sellableServices("SALON")`) and send `locationType: "SALON"` as a
// literal — so a mobile-only pro was told "you don't have a bookable in-salon
// location", which was true and useless, and web's modal did the same thing in
// its own words. Both now ask
// `GET /api/v1/pro/waitlist/{entryId}/offer` (`waitlistOfferOptions`), which
// answers from the same two resolvers the POST re-runs under the professional's
// lock — so every option shown is one the send will accept, and the two platforms
// cannot disagree about what a pro may offer.
//
// 🔴 Nothing about the client's address is on this device, in any response it
// reads. A mobile option carries the PRO's own base; the destination is resolved
// server-side from the waitlist entry — for the availability query
// (`waitlistEntryId`, never `clientAddressId`) and for the offer alike. The pro
// learns how far and roughly where once the offer exists, and the exact address
// only once the client accepts it.
import SwiftUI
import TovisKit

struct ProWaitlistOfferSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    // Identified by the bare entry id + the client's name rather than a whole
    // `ProWaitlistEntry`, because the pro calendar reaches this sheet too and its
    // waitlist rows are `ProCalendarEvent`s, not outreach entries. These are the
    // same four props web's `WaitlistOfferModal` takes.
    let waitlistEntryId: String
    let clientName: String
    let serviceId: String
    let serviceName: String
    /// Called on a successful offer with the client's name so the caller can
    /// confirm ("Offer sent to …") and reload.
    var onOffered: (String) -> Void

    /// Everything needed to run the availability picker + send the offer. The
    /// mode options come from the server; `professionalId` is the only piece
    /// still resolved locally, because the availability query needs it and it is
    /// the pro's own id.
    private struct OfferContext {
        let professionalId: String
        let offeringId: String
        let options: [ProWaitlistOfferOption]
    }

    private enum Phase {
        case loading
        case ready(OfferContext)
        /// Can't offer a time — the server's own sentence for why.
        case blocked(String)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var selectedSlot: String?
    /// Which of the server's options is selected. Index rather than the value so
    /// the segmented control binds directly.
    @State private var modeIndex = 0
    /// The open-slot picker's day (see ProOpenSlotPicker.selectedDate).
    @State private var slotDay = Date()
    @State private var sending = false
    @State private var sendError: String?

    private var canSend: Bool {
        if case let .ready(ctx) = phase {
            return selectedOption(ctx) != nil && selectedSlot != nil && !sending
        }
        return false
    }

    private func selectedOption(_ ctx: OfferContext) -> ProWaitlistOfferOption? {
        guard ctx.options.indices.contains(modeIndex) else { return ctx.options.first }
        return ctx.options[modeIndex]
    }

    /// "Mobile", or the salon location's name. Matches web's `modeLabel`.
    private func modeLabel(_ option: ProWaitlistOfferOption) -> String {
        if option.isMobile { return "Mobile" }
        let name = option.locationName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "In-salon" : name
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Propose a time to \(displayClientName) for \(serviceName). They’ll confirm before it books.")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    switch phase {
                    case .loading:
                        HStack(spacing: 8) {
                            ProgressView().tint(BrandColor.accent)
                            Text("Loading your availability…")
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                        .padding(.top, 8)
                    case let .blocked(message):
                        BrandSurface {
                            Text(message)
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case let .failed(message):
                        failedState(message)
                    case let .ready(ctx):
                        readyBody(ctx)
                    }
                }
                .padding(20)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Offer a time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(BrandColor.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Sending…" : "Send offer") {
                        if case let .ready(ctx) = phase { Task { await send(ctx) } }
                    }
                    .disabled(!canSend)
                    .tint(BrandColor.accent)
                }
            }
            .tint(BrandColor.accent)
        }
        .task { await load() }
    }

    @ViewBuilder
    private func readyBody(_ ctx: OfferContext) -> some View {
        if let option = selectedOption(ctx) {
            if ctx.options.count > 1 {
                Picker("Where", selection: $modeIndex) {
                    ForEach(Array(ctx.options.enumerated()), id: \.element.id) { index, mode in
                        Text(modeLabel(mode)).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                // A slot is only valid for the mode it was computed in.
                .onChange(of: modeIndex) { _, _ in selectedSlot = nil }
            }

            if option.isMobile {
                Text("You’ll travel to \(displayClientName). Once they accept, their address appears on the booking.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ProOpenSlotPicker(
                professionalId: ctx.professionalId,
                serviceId: serviceId,
                offeringId: ctx.offeringId,
                locationId: option.locationId,
                locationType: option.locationType,
                locationTimeZone: option.timeZone,
                // 🔴 No client address, on either path. A mobile day's placement
                // is resolved server-side from the entry id below.
                waitlistEntryId: waitlistEntryId,
                selectedSlot: $selectedSlot,
                selectedDate: $slotDay
            )

            if let sendError {
                Text(sendError)
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.ember)
            }

            if !option.timeZone.isEmpty {
                Text("Times are in \(option.timeZone).")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    private func failedState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { Task { await load() } } label: {
                Text("Try again")
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 22)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    /// The name as the sentence reads it — a waitlist row can arrive without one.
    private var displayClientName: String {
        clientName.isEmpty ? "this client" : clientName
    }

    // MARK: - Data

    private func load() async {
        phase = .loading
        selectedSlot = nil
        modeIndex = 0
        sendError = nil
        do {
            async let profileTask = session.client.proProfile.myProfile()
            async let optionsTask = session.client.proSchedule.waitlistOfferOptions(
                waitlistEntryId: waitlistEntryId
            )
            let professionalId = try await profileTask.id
            let offerOptions = try await optionsTask

            guard let offeringId = offerOptions.offeringId,
                  !offerOptions.options.isEmpty
            else {
                // The server's own sentence — one wording, both platforms, and it
                // names what to fix rather than what happens to be missing here.
                phase = .blocked(
                    offerOptions.blockedReason
                        ?? "There’s no time to offer for \(serviceName) yet. Add or activate the service and a bookable location first."
                )
                return
            }

            phase = .ready(OfferContext(
                professionalId: professionalId,
                offeringId: offeringId,
                options: offerOptions.options
            ))
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your availability just now. Please try again.")
        }
    }

    private func send(_ ctx: OfferContext) async {
        guard let slot = selectedSlot, let option = selectedOption(ctx), !sending else { return }
        guard let start = Wire.date(slot) else {
            sendError = "That time couldn’t be read. Pick another."
            return
        }
        sending = true
        sendError = nil
        defer { sending = false }

        // endsAt = the chosen start + the mode's duration (the web modal derives it
        // from the picked slot's end; iOS's picker yields only the start instant).
        // The duration is the server's answer for THIS mode — mobile and in-salon
        // legitimately differ.
        let endIso = ProCalendarGrid.iso(
            start.addingTimeInterval(Double(option.durationMinutes) * 60)
        )

        do {
            _ = try await session.client.proSchedule.offerWaitlistSlot(
                waitlistEntryId: waitlistEntryId,
                scheduledFor: slot,
                endsAt: endIso,
                locationId: option.locationId,
                locationType: option.locationType,
                durationMinutes: option.durationMinutes
            )
            onOffered(displayClientName)
            dismiss()
        } catch let error as APIError {
            sendError = error.userMessage
        } catch {
            sendError = "Couldn’t send the offer. Please try again."
        }
    }
}
