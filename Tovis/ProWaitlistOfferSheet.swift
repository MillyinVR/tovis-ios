// Offer-a-time sheet for the pro waitlist workspace — the native port of the web
// `WaitlistOfferModal` (`app/pro/calendar/_components/WaitlistOfferModal.tsx`).
// Proposes a concrete in-salon appointment time to a waitlisted client: pick a
// slot from the pro's live availability, then POST /api/v1/pro/waitlist/{entryId}/offer
// (an existing route — no backend change). The route creates a PENDING offer and
// notifies the client, who Confirms/Declines before it books.
//
// Unlike the web modal — which is handed the offering + salon location by the
// calendar surface — this sheet resolves them itself from the pro's own context:
//   • professionalId ← proProfile.myProfile()
//   • in-salon location ← proCalendar.locations() (bookable SALON/SUITE, primary
//     first — mirrors web's `offerSalonLocation`)
//   • offeringId + duration ← proBookings.sellableServices("SALON") matched on the
//     row's serviceId (absent ⇒ no active in-salon offering ⇒ blocked, matching
//     web's `offeringId === null` empty state)
// so it can be reached straight from a waitlist row — the outreach workspace's
// (`ProWaitlistView`) and the pro calendar's management sheet's alike.
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

    /// The resolved context needed to run the availability picker + send the offer.
    private struct OfferContext {
        let professionalId: String
        let offeringId: String
        let durationMinutes: Int
        let locationId: String
        let locationTimeZone: String?
    }

    private enum Phase {
        case loading
        case ready(OfferContext)
        /// Can't offer a time (no active in-salon offering, or no bookable salon).
        case blocked(String)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var selectedSlot: String?
    @State private var sending = false
    @State private var sendError: String?

    private var canSend: Bool {
        if case .ready = phase { return selectedSlot != nil && !sending }
        return false
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
        ProOpenSlotPicker(
            professionalId: ctx.professionalId,
            serviceId: serviceId,
            offeringId: ctx.offeringId,
            locationId: ctx.locationId,
            locationType: "SALON",
            locationTimeZone: ctx.locationTimeZone,
            durationMinutes: ctx.durationMinutes,
            selectedSlot: $selectedSlot
        )

        if let sendError {
            Text(sendError)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(BrandColor.ember)
        }

        if let zone = ctx.locationTimeZone, !zone.isEmpty {
            Text("Times are in \(zone).")
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textMuted)
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

    /// Bookable in-salon location (SALON or SUITE) — mirrors web `offerSalonLocation`.
    private func isInSalon(_ loc: ProLocationSummary) -> Bool {
        loc.type == "SALON" || loc.type == "SUITE"
    }

    private func load() async {
        phase = .loading
        selectedSlot = nil
        sendError = nil
        do {
            async let profileTask = session.client.proProfile.myProfile()
            async let locationsTask = session.client.proCalendar.locations()
            async let servicesTask = session.client.proBookings.sellableServices(locationType: "SALON")
            let professionalId = try await profileTask.id
            let locations = try await locationsTask
            let services = try await servicesTask

            // In-salon location the offer anchors to: bookable SALON/SUITE, primary
            // first (mirrors web's `offerSalonLocation`).
            let salon = locations.first { $0.isBookable && isInSalon($0) && $0.isPrimary }
                ?? locations.first { $0.isBookable && isInSalon($0) }
            guard let salon else {
                phase = .blocked("You don’t have a bookable in-salon location yet, so there’s no time to offer. Add one in your locations first.")
                return
            }

            // The pro's active in-salon offering for this service. Absent ⇒ nothing
            // to offer (matches web's null-offering empty state).
            guard let match = services.first(where: { $0.id == serviceId }) else {
                phase = .blocked("You don’t have an active in-salon offering for \(serviceName), so there’s no time to offer yet. Add or activate the service first.")
                return
            }

            phase = .ready(OfferContext(
                professionalId: professionalId,
                offeringId: match.offeringId,
                durationMinutes: match.selectedMode?.durationMinutes ?? 60,
                locationId: salon.id,
                locationTimeZone: salon.timeZone
            ))
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your availability just now. Please try again.")
        }
    }

    private func send(_ ctx: OfferContext) async {
        guard let slot = selectedSlot, !sending else { return }
        guard let start = Wire.date(slot) else {
            sendError = "That time couldn’t be read. Pick another."
            return
        }
        sending = true
        sendError = nil
        defer { sending = false }

        // endsAt = the chosen start + the offering's duration (the web modal derives
        // it from the picked slot's end; iOS's picker yields only the start instant).
        let endIso = ProCalendarGrid.iso(
            start.addingTimeInterval(Double(ctx.durationMinutes) * 60)
        )

        do {
            _ = try await session.client.proSchedule.offerWaitlistSlot(
                waitlistEntryId: waitlistEntryId,
                scheduledFor: slot,
                endsAt: endIso,
                locationId: ctx.locationId,
                durationMinutes: ctx.durationMinutes
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
