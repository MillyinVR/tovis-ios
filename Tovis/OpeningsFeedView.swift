// Client last-minute openings feed — the native counterpart to the web
// /client/openings page (app/client/(gated)/openings/OpeningsFeedClient.tsx),
// backed by GET /api/v1/client/openings. A list of freed-up slots the client is a
// recipient of; each card shows the service, pro, time, and a discounted price, and
// tapping it opens the dedicated claim sheet for that exact time — the same
// destination as the web "Grab it →" link (/offerings/{id}?scheduledFor=…&openingId=…),
// which is a one-button claim page with no picker on it. Pushed inside the host tab's
// NavigationStack (from the Home "Last-minute openings" card), so it owns no stack.
import SwiftUI
import TovisKit

struct OpeningsFeedView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded([ClientOpening])
        case failed(String)
    }

    /// The opening whose claim sheet is open. The sheet renders from this row
    /// alone — no profile or availability fetch stands between "Grab it" and a
    /// working claim button.
    private struct ClaimTarget: Identifiable {
        let opening: ClientOpening
        var id: String { opening.opening.id }
    }

    /// Pro-profile fallback push when an opening's offering can't be resolved
    /// (inactive / no longer on the profile) — the client can still reach the pro.
    private struct ProNav: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @State private var phase: Phase = .loading
    @State private var claimTarget: ClaimTarget?
    @State private var proNav: ProNav?
    /// The booking a completed claim produced, pushed once the sheet dismisses —
    /// web's `router.push('/booking/{id}')` after finalize.
    @State private var claimedBooking: ClientBookingNav?
    /// Non-nil when the claim succeeded but its booking could not be loaded for
    /// the push; the claim itself still landed, so this is informational.
    @State private var claimNoticeShown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 60)
                case let .failed(message):
                    errorState(message)
                case let .loaded(openings):
                    content(openings)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Openings")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .navigationDestination(item: $proNav) { nav in
            ProProfileView(professionalId: nav.id, fallbackName: nav.name)
        }
        .navigationDestination(item: $claimedBooking) { nav in
            BookingDetailView(booking: nav.booking, onDecision: { session.signalRefresh() })
        }
        .sheet(item: $claimTarget) { target in
            ClaimOpeningView(opening: target.opening) { bookingId in
                Task { await openClaimedBooking(bookingId) }
            }
        }
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
        .onChange(of: session.refreshTick) { Task { await load() } }
        .alert("You’re booked", isPresented: $claimNoticeShown) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The opening is yours. You’ll find it in Appointments.")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ openings: [ClientOpening]) -> some View {
        Text("Slots that just freed up. Grab one before it’s gone — first to claim it wins.")
            .font(BrandFont.body(13))
            .foregroundStyle(BrandColor.textSecondary)

        if openings.isEmpty {
            emptyState
        } else {
            VStack(spacing: 12) {
                ForEach(openings) { opening in
                    card(opening)
                }
            }
        }
    }

    private var emptyState: some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 6) {
                Text("No openings right now")
                    .font(BrandFont.body(14, .bold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text("When a pro frees up a last-minute spot you’re waiting on, it’ll show up here — we’ll ping you the moment one lands.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func card(_ opening: ClientOpening) -> some View {
        Button {
            open(opening)
        } label: {
            BrandSurface(tint: BrandColor.bgSecondary) {
                cardBody(opening)
            }
        }
        .buttonStyle(.plain)
    }

    private func cardBody(_ opening: ClientOpening) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if opening.matchedWaitlist {
                BrandPill(text: "✦ Matches your waitlist", tint: BrandColor.accent)
            }

            // The incentive leads the card. It used to sit under the price at 9pt
            // in gold — the single most persuasive thing on a last-minute opening,
            // rendered smaller than everything around it.
            if let headline = opening.incentiveHeadline {
                Text("✦ \(headline)")
                    .font(BrandFont.body(17, .bold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(alignment: .top, spacing: 12) {
                BrandAvatar(
                    name: opening.proName,
                    avatarUrl: opening.opening.professional.avatarUrl,
                    size: 50
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(opening.serviceName)
                        .font(BrandFont.body(16, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    Text(opening.meta)
                        .font(BrandFont.body(12.5))
                        .foregroundStyle(BrandColor.textMuted)
                        .lineLimit(1)
                    whenChip(opening)
                }
                Spacer(minLength: 8)
                priceColumn(opening)
            }

            HStack {
                Spacer()
                Text("Grab it →")
                    .font(BrandFont.body(13, .bold))
                    .foregroundStyle(BrandColor.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func whenChip(_ opening: ClientOpening) -> some View {
        let when = Wire.dateTime(opening.startAt, timeZone: opening.timeZone)
        if !when.isEmpty {
            Text(when)
                .font(BrandFont.body(11, .bold))
                .foregroundStyle(BrandColor.gold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(BrandColor.gold.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func priceColumn(_ opening: ClientOpening) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            if opening.hasDiscount, let was = Wire.moneyDecimal(opening.basePrice) {
                Text(was)
                    .font(BrandFont.body(11))
                    .foregroundStyle(BrandColor.textMuted)
                    .strikethrough()
            }
            // "From", because these are STARTING prices — the pro sets the final
            // one at the consultation. The underlying fields say so
            // (salonPriceStartingAt / minPrice); the card shouldn't quote them as
            // if they were settled.
            if let price = Wire.moneyDecimal(opening.finalPrice) {
                Text("From \(price)")
                    .font(BrandFont.body(18, .bold))
                    .foregroundStyle(BrandColor.accent)
            }
        }
    }

    // MARK: - Actions

    /// Open the claim sheet for this exact opening.
    ///
    /// This used to resolve the pro's profile, find the offering and open the
    /// generic BookingFlowView — a calendar plus a slot grid built from GENERAL
    /// availability. That was a trap: `finalize` refuses any time that isn't the
    /// opening's own, so the picker invited a choice the server would reject. The
    /// row already carries everything a claim needs, so there is nothing to
    /// resolve and nothing to pick.
    ///
    /// An opening with no offering isn't claimable at all (`isBookable` already
    /// filters those out of the feed); route those to the pro instead.
    private func open(_ opening: ClientOpening) {
        guard opening.isBookable else {
            proNav = ProNav(id: opening.opening.professionalId, name: opening.proName)
            return
        }
        claimTarget = ClaimTarget(opening: opening)
    }

    /// After a successful claim, land the client on their new booking — web's
    /// `router.push('/booking/{id}')`. The claim has already succeeded by the time
    /// this runs, so a failed lookup is a navigation miss, not a booking failure,
    /// and says so rather than implying the claim didn't land.
    private func openClaimedBooking(_ bookingId: String) async {
        session.signalRefresh()
        if let booking = try? await session.client.bookings.booking(id: bookingId) {
            claimedBooking = ClientBookingNav(booking: booking)
        } else {
            claimNoticeShown = true
        }
        await load()
    }

    private func load() async {
        do {
            let openings = try await session.client.home.openings().filter { $0.isBookable }
            phase = .loaded(openings)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load openings.")
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button { Task { await load() } } label: {
                Text("Try again")
                    .font(BrandFont.body(15, .semibold))
                    .foregroundStyle(BrandColor.onAccent)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
    }
}
