// Dedicated claim sheet for a last-minute opening — the native counterpart of
// web's claim page (app/(main)/offerings/[offeringId]/page.tsx + ClaimClient.tsx).
//
// WHY THIS EXISTS. "Grab it" used to open the generic BookingFlowView: a full
// calendar and a slot grid built from GENERAL availability, with the opening's
// instant preselected only when it happened to appear in that grid. That was not
// just extra taps — it was a trap. `finalize` validates the booked time against
// the opening and throws OPENING_NOT_AVAILABLE when they differ, so the picker
// invited a choice that the server then refused. An opening is ONE time; this
// screen offers exactly that time, and nothing else.
//
// It renders entirely from the `ClientOpening` the feed already holds — pro,
// service, exact time, place, duration, price with its incentive — so the button
// is live on first frame with no availability round-trips behind it.
import SwiftUI
import TovisKit

struct ClaimOpeningView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let opening: ClientOpening

    /// Pushed after a successful claim so the client lands on their booking.
    var onClaimed: (String) -> Void = { _ in }

    private enum Phase: Equatable {
        case ready
        /// The opening is gone — web's "Someone just grabbed it" card.
        case taken
    }

    /// One state for every sheet this view can present. A SECOND `.sheet`
    /// modifier would silently shadow the first and turn one of them into a dead
    /// button — the regression #175 shipped and #176 fixed.
    private enum ClaimSheet: Identifiable {
        case addAddress
        case pickAnotherTime(ProOffering)

        var id: String {
            switch self {
            case .addAddress: return "addAddress"
            case let .pickAnotherTime(offering): return "pickAnotherTime:\(offering.id)"
            }
        }
    }

    @State private var phase: Phase = .ready
    @State private var claiming = false
    @State private var claimError: String?
    @State private var sheet: ClaimSheet?

    /// Presence chips, already reduced to what is honest to show. These moved here
    /// from BookingFlowView with the claim itself: web renders PresenceSignals on
    /// the CLAIM page, and this is now that page.
    @State private var presence: PresenceDisplay = .empty

    // Mobile openings bill to the client's default service address, exactly as
    // web's claim page does (it resolves `defaultAddressId` server-side and bails
    // out to "add an address" when there is none). Only fetched for MOBILE.
    @State private var addresses: [ClientAddress] = []
    @State private var addressesLoaded = false

    // M15: the pro's no-show/late-cancel fee policy the client must agree to
    // before claiming. nil → no fee → no gate.
    @State private var cancellationPolicy: String?
    @State private var policyAccepted = false

    /// Resolving the offering for the "pick another time" fallback — deliberately
    /// lazy, so the ordinary claim never pays for it.
    @State private var resolvingFallback = false

    private var defaultAddressId: String? {
        (addresses.first { $0.isDefault } ?? addresses.first)?.id
    }

    /// MOBILE with no saved service address: web shows a message pointing at the
    /// address form rather than claiming into a dead end.
    private var needsAddress: Bool {
        opening.isMobile && addressesLoaded && defaultAddressId == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch phase {
                    case .ready:
                        details
                    case .taken:
                        takenCard
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Opening")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }.tint(BrandColor.textSecondary)
                }
            }
            // Both presence loops hang off the NavigationStack content, which
            // ALWAYS exists — never off the chips, which render nothing until
            // there is something honest to say. A `.task` on a view that resolves
            // to empty never installs (the dead-but-green failure from #173).
            // Multiple `.task`s are additive; only PRESENTATIONS shadow.
            .task { await runPresenceHeartbeat() }
            .task { await runPresencePoll() }
            .task { await loadAddressesIfMobile() }
            .task { await loadCancellationPolicy() }
            .sheet(item: $sheet) { which in
                switch which {
                case .addAddress:
                    AddServiceAddressSheet { saved in
                        addresses.insert(saved, at: 0)
                        addressesLoaded = true
                    }
                case let .pickAnotherTime(offering):
                    BookingFlowView(
                        professionalId: opening.opening.professionalId,
                        proName: opening.proName,
                        offering: offering,
                        locationType: opening.claimLocationType,
                        preselectedSlot: opening.startAt
                        // Deliberately NO openingId: this is the fallback for a
                        // slot that could not be held, so the client is choosing
                        // a DIFFERENT time. Threading the opening through would
                        // hand finalize a time that cannot match it and turn the
                        // fallback into the same trap this screen replaced.
                    )
                }
            }
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Detail (mirrors the web claim page, top to bottom)

    @ViewBuilder
    private var details: some View {
        Text("🔔 Opening available")
            .font(BrandFont.mono(10))
            .kerning(1.6)
            .foregroundStyle(BrandColor.accent)

        Text(opening.serviceName)
            .font(BrandFont.display(32, .bold))
            .foregroundStyle(BrandColor.textPrimary)
            .padding(.top, 10)

        Text([opening.proName, opening.professionLabel].compactMap { $0 }.joined(separator: " · "))
            .font(BrandFont.body(14))
            .foregroundStyle(BrandColor.textMuted)
            .padding(.top, 6)

        incentiveBanner

        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    factCell("When", whenLine)
                    factCell("Where", opening.placeLine ?? "—")
                }
                HStack(alignment: .top, spacing: 16) {
                    if let minutes = opening.durationMinutes {
                        factCell("Duration", "\(minutes) min")
                    }
                    priceCell
                }

                // Says out loud what "starting at" means, on the screen where
                // someone is about to commit: the pro prices the work once they
                // see the hair, and the discount rides on that final number.
                Text(opening.hasDiscount
                     ? "Starting price — your pro confirms the final price at your appointment. Your discount applies to it."
                     : "Starting price — your pro confirms the final price at your appointment.")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                PresenceSignalsBadges(display: presence)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 22)

        if needsAddress {
            noticeCard(
                "Add a service address to claim a mobile opening.",
                actionTitle: "Add an address",
                action: { sheet = .addAddress }
            )
        }

        if let claimError {
            noticeCard(claimError, actionTitle: nil, action: nil)
        }

        if let cancellationPolicy {
            VStack(alignment: .leading, spacing: 10) {
                Text(cancellationPolicy)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
                Toggle(isOn: $policyAccepted) {
                    Text("I agree to this cancellation policy")
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                }
                .tint(BrandColor.accent)
            }
            .padding(.top, 16)
        }

        Button { Task { await claim() } } label: {
            Group {
                if claiming {
                    ProgressView().tint(BrandColor.onAccent)
                } else {
                    Text("Claim this opening →").font(BrandFont.body(17, .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(BrandColor.onAccent)
            .background(
                claimDisabled ? BrandColor.textMuted.opacity(0.4) : BrandColor.accent
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .disabled(claimDisabled)
        .padding(.top, 20)

        Text("PAY AT YOUR BOOKING · FIRST TO CLAIM GETS IT")
            .font(BrandFont.mono(10))
            .kerning(0.8)
            .foregroundStyle(BrandColor.textMuted)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
    }

    /// The deal, as the loudest thing on the screen.
    ///
    /// A pro creating a last-minute opening picks ONE incentive — percent off,
    /// dollar amount off, a free service, or a free add-on — and that is what
    /// makes the slot worth dropping everything for. The starting price isn't
    /// even final (the pro re-quotes at the appointment), so it has no business
    /// outshouting the offer. Renders nothing when the opening carries no
    /// incentive, rather than reserving empty space for one.
    @ViewBuilder
    private var incentiveBanner: some View {
        if let headline = opening.incentiveHeadline {
            VStack(alignment: .leading, spacing: 2) {
                Text("✦ \(headline)")
                    .font(BrandFont.display(30, .bold))
                    .foregroundStyle(BrandColor.onAccent)
                    .minimumScaleFactor(0.6)
                    .lineLimit(2)
                if let subline = opening.incentiveSubline {
                    Text(subline)
                        .font(BrandFont.body(12.5, .medium))
                        .foregroundStyle(BrandColor.onAccent.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(BrandColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.top, 20)
        }
    }

    private func factCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(BrandFont.mono(9))
                .kerning(1)
                .foregroundStyle(BrandColor.textMuted)
            Text(value)
                .font(BrandFont.body(15, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A STARTING price, never a set one.
    ///
    /// The underlying fields say so themselves — `salonPriceStartingAt`,
    /// `mobilePriceStartingAt`, `service.minPrice` — and the pro sets the real
    /// price at the consultation once they've seen the hair. Rendering a bare
    /// "$144" on the screen where someone commits to a booking reads as a quote,
    /// so the label, the "From", and the footnote all say otherwise. The discount
    /// is real and applies to whatever the final price turns out to be.
    private var priceCell: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("STARTING AT")
                .font(BrandFont.mono(9))
                .kerning(1)
                .foregroundStyle(BrandColor.textMuted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let final = Wire.moneyDecimal(opening.finalPrice) {
                    Text("From \(final)")
                        .font(BrandFont.body(15, .bold))
                        .foregroundStyle(opening.hasDiscount ? BrandColor.accent : BrandColor.textPrimary)
                } else {
                    Text("—").font(BrandFont.body(15, .bold)).foregroundStyle(BrandColor.textPrimary)
                }
                if opening.hasDiscount, let was = Wire.moneyDecimal(opening.basePrice) {
                    Text(was)
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                        .strikethrough()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func noticeCard(
        _ message: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(BrandFont.body(13, .semibold))
                    .tint(BrandColor.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(BrandColor.ember.opacity(0.3), lineWidth: 1)
        )
        .padding(.top, 16)
    }

    /// Web's "Someone just grabbed it" card, verbatim — plus the native shape of
    /// its "See more openings" link, which on iOS is simply going back to the feed
    /// the sheet was opened from.
    private var takenCard: some View {
        VStack(spacing: 10) {
            Text("Someone just grabbed it")
                .font(BrandFont.display(19, .bold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("This opening was claimed by someone else. There may be others available.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
            Button {
                session.signalRefresh()
                dismiss()
            } label: {
                Text("See more openings")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(BrandColor.accent)
                    .clipShape(Capsule())
            }
            .padding(.top, 6)

            Button {
                Task { await openFallbackPicker() }
            } label: {
                if resolvingFallback {
                    ProgressView().tint(BrandColor.accent)
                } else {
                    Text("Pick another time with \(opening.proName)")
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.accent)
                }
            }
            .disabled(resolvingFallback)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var whenLine: String {
        let when = Wire.dateTime(opening.startAt, timeZone: opening.timeZone)
        return when.isEmpty ? "—" : when
    }

    // MARK: - Claim

    /// hold → finalize on the opening's OWN instant, exactly as web's ClaimClient
    /// does. No slot is ever chosen here, so the time can never disagree with the
    /// opening.
    ///
    /// `finalize` builds its own deterministic idempotency key from the hold id +
    /// payload (BookingService), so a double tap replays instead of double-booking.
    private var claimDisabled: Bool {
        claiming || (cancellationPolicy != nil && !policyAccepted)
    }

    /// The pro's fee policy the client must agree to (M15). Best-effort: reuses the
    /// add-ons endpoint (which carries the disclosure); a failure just hides it.
    private func loadCancellationPolicy() async {
        guard let offeringId = opening.offeringId else { return }
        let result = try? await session.client.booking.addOns(
            offeringId: offeringId, locationType: opening.claimLocationType
        )
        cancellationPolicy = result?.cancellationPolicy
    }

    private func claim() async {
        guard !claiming else { return }

        guard let offeringId = opening.offeringId else {
            claimError = "This opening is no longer bookable."
            return
        }

        if cancellationPolicy != nil && !policyAccepted {
            claimError = "Please agree to the cancellation policy to book."
            return
        }

        if opening.isMobile {
            // The address load is cheap and MOBILE-only; make sure it has landed
            // before deciding there is no address to bill to.
            await loadAddressesIfMobile()
            guard defaultAddressId != nil else {
                claimError = nil
                return // `needsAddress` renders the "add an address" card.
            }
        }

        claiming = true
        claimError = nil
        defer { claiming = false }

        do {
            let hold = try await session.client.booking.createHold(
                offeringId: offeringId,
                locationId: opening.claimLocationId,
                scheduledFor: opening.startAt,
                locationType: opening.claimLocationType,
                clientAddressId: opening.isMobile ? defaultAddressId : nil
            )
            let booking = try await session.client.booking.finalize(
                holdId: hold.id,
                offeringId: offeringId,
                locationType: opening.claimLocationType,
                addOnIds: [],
                openingId: opening.opening.id,
                cancellationPolicyAccepted: policyAccepted
            )
            session.signalRefresh()
            dismiss()
            onClaimed(booking.id)
        } catch let error as APIError {
            // A 409 does NOT automatically mean "someone grabbed it" — see
            // OpeningClaimFailure, which branches on the code.
            switch OpeningClaimFailure.classify(error) {
            case .taken:
                phase = .taken
            case let .failed(message):
                claimError = message
            }
        } catch {
            claimError = "Couldn’t claim this opening. Please try again."
        }
    }

    /// The escape hatch after a lost race: resolve the offering on the pro's
    /// profile and open the ordinary booking flow. Only ever reached from the
    /// "taken" card, so nobody pays for the profile fetch on the happy path.
    private func openFallbackPicker() async {
        guard !resolvingFallback, let serviceId = opening.serviceId else { return }
        resolvingFallback = true
        defer { resolvingFallback = false }

        guard
            let profile = try? await session.client.profiles.professional(
                id: opening.opening.professionalId
            ),
            let offering = profile.offerings.first(where: { $0.serviceId == serviceId })
        else {
            claimError = "Couldn’t open this pro’s times. Please try again."
            return
        }
        sheet = .pickAnotherTime(offering)
    }

    private func loadAddressesIfMobile() async {
        guard opening.isMobile, !addressesLoaded else { return }
        addresses = (try? await session.client.addresses.serviceAddresses()) ?? []
        addressesLoaded = true
    }

    // MARK: - Presence (moved here from BookingFlowView with the claim)

    /// Heartbeat AND read, because web's "N watching now" threshold is written for
    /// a viewer who counts themselves — reading without heartbeating would
    /// silently reinterpret the same number as "two OTHER people" and leave iOS
    /// viewers invisible in everyone else's count (#179).
    private func runPresenceHeartbeat() async {
        while !Task.isCancelled {
            _ = try? await session.client.presence.heartbeat(
                resourceType: .opening,
                resourceId: opening.opening.id
            )
            try? await Task.sleep(for: PresenceHeartbeat.interval)
        }
    }

    /// Web's cadence: 15s while the counts move, 30s once they have been still for
    /// three rounds. Failures are deliberately silent — presence is ambient, the
    /// user never asked for it, and "no badge" already covers below-threshold,
    /// unknown and empty.
    private func runPresencePoll() async {
        var schedule = PresencePollSchedule()
        var previous: PresenceSignals?

        while !Task.isCancelled {
            let signals = try? await session.client.presence.signals(
                resourceType: .opening,
                resourceId: opening.opening.id,
                professionalId: opening.opening.professionalId,
                serviceId: opening.serviceId
            )
            if let signals {
                // Only a round that actually answered can count as "unchanged".
                schedule.record(unchanged: signals == previous)
                previous = signals
                presence = PresenceDisplay(signals: signals)
            }
            try? await Task.sleep(for: schedule.nextInterval)
        }
    }
}
