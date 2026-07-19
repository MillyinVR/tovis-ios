// Client priority-offers screen — the native counterpart to the web
// /client/offers page (app/client/(gated)/offers). It merges the same two feeds
// the web page stacks:
//
//   • "Times offered to you"  — pro-proposed waitlist times
//     (GET /client/waitlist-offers). Confirm books the appointment and opens it;
//     Decline frees the pro to offer another. Mirrors WaitlistOfferCards.
//   • "Your priority offers"  — last-minute openings this client is first in line
//     for (GET /client/priority-offer), each with a live countdown. Claim accepts
//     the priority window and opens ClaimOpeningView on the opening's own instant
//     — a single-slot claim, the same shape web routes to (/offerings/{id}?
//     scheduledFor=…, a page with no picker); Pass gives it to the next person.
//     Mirrors OffersListClient.
//
// Reached from a tapped last-minute-offer push (`.offers` deep link, which the
// backend sends as `/client/offers?accept={recipientId}`) and from the Home
// "Last-minute openings" card. Owns no NavigationStack — pushed inside the host
// tab's stack, or wrapped in one when presented as a sheet by the deep-link route.
import SwiftUI
import Combine
import TovisKit

struct PriorityOffersView: View {
    @Environment(SessionModel.self) private var session

    /// The recipient id from `?accept=` on the priority-offer push — that offer is
    /// floated to the top and highlighted, mirroring the web `?accept=` behavior.
    var highlightRecipientId: String? = nil

    private enum Phase {
        case loading
        case loaded(priority: [ClientPriorityOffer], waitlist: [ClientWaitlistOffer])
        case failed(String)
    }

    /// The accepted offer's opening, claimed on its own instant via
    /// ClaimOpeningView — the same sheet the openings feed uses (#180), so there is
    /// exactly one claim implementation and it can never offer a time the server
    /// will refuse. Resolution lives in `ClientPriorityOffer.claimableOpening`.
    private struct ClaimTarget: Identifiable {
        let opening: ClientOpening
        var id: String { opening.opening.id }
    }

    /// Pro-profile fallback push when a claimed offer's offering can't be resolved
    /// (inactive / no longer on the profile) — the client can still reach the pro.
    private struct ProNav: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @State private var phase: Phase = .loading
    /// Ticks every second so the countdowns re-render live.
    @State private var now = Date()
    /// The offer/recipient id currently mid-action, for a spinner + disable.
    @State private var busy: String?
    @State private var claimTarget: ClaimTarget?
    @State private var proNav: ProNav?
    @State private var bookingNav: ClientBookingNav?
    @State private var actionError: String?

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 60)
                case let .failed(message):
                    errorState(message)
                case let .loaded(priority, waitlist):
                    content(priority: priority, waitlist: waitlist)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Offers")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .navigationDestination(item: $proNav) { nav in
            ProProfileView(professionalId: nav.id, fallbackName: nav.name)
        }
        .navigationDestination(item: $bookingNav) { nav in
            BookingDetailView(booking: nav.booking, onDecision: { session.signalRefresh() })
        }
        .sheet(item: $claimTarget) { target in
            ClaimOpeningView(opening: target.opening) { bookingId in
                Task { await openClaimedBooking(bookingId) }
            }
        }
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
        .onReceive(ticker) { now = $0 }
        .onChange(of: session.refreshTick) { Task { await load() } }
        .alert("Couldn’t do that", isPresented: actionErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "Please try again in a moment.")
        }
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
    }

    // MARK: - Content

    @ViewBuilder
    private func content(priority: [ClientPriorityOffer], waitlist: [ClientWaitlistOffer]) -> some View {
        // "Times offered to you" — pro-proposed waitlist times (only when present).
        if !waitlist.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    "Times offered to you",
                    "A pro you’re waitlisted with proposed a specific time. Confirm to book it, or decline to wait for another."
                )
                ForEach(waitlist) { offer in waitlistCard(offer) }
            }
        }

        // "Your priority offers" — always rendered (its own empty note when none),
        // mirroring the web OffersListClient.
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                "Your priority offers",
                "You’re first in line for these last-minute openings. Claim before the timer runs out, or pass to give it to the next person."
            )
            if priority.isEmpty {
                priorityEmpty
            } else {
                ForEach(sortedPriority(priority)) { offer in priorityCard(offer) }
            }
        }
    }

    private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(BrandFont.body(17, .bold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(subtitle)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    private var priorityEmpty: some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            Text("No active offers right now. When a spot opens up for a service you’re waitlisted for, you’ll get first dibs here.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Priority offer card

    @ViewBuilder
    private func priorityCard(_ offer: ClientPriorityOffer) -> some View {
        let expired = offer.isExpired(now: now)
        let highlighted = offer.recipientId == highlightRecipientId
        BrandSurface(tint: highlighted ? BrandColor.accent.opacity(0.08) : BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    BrandAvatar(name: offer.proName, avatarUrl: offer.avatarUrl, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(offer.serviceLabel)
                                .font(BrandFont.body(15.5, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                                .lineLimit(1)
                            if let incentive = offer.incentiveLabel {
                                BrandPill(text: "✦ \(incentive)", tint: BrandColor.accent)
                            }
                        }
                        Text(subtitleLine(proName: offer.proName, startAt: offer.startAt, timeZone: offer.timeZone))
                            .font(BrandFont.body(12.5))
                            .foregroundStyle(BrandColor.textMuted)
                            .lineLimit(1)
                        if let note = offer.note, !note.trimmingCharacters(in: .whitespaces).isEmpty {
                            Text(note)
                                .font(BrandFont.body(12.5))
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                    }
                    Spacer(minLength: 8)
                    countdownChip(offer, expired: expired)
                }

                if expired {
                    Text("This window has passed. The opening may have gone to the next person in line.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                } else {
                    HStack(spacing: 10) {
                        Button { Task { await claim(offer) } } label: {
                            actionLabel(busy == offer.recipientId ? "…" : "Claim it", filled: true)
                        }
                        .disabled(busy != nil)
                        Button { Task { await pass(offer) } } label: {
                            actionLabel("Pass", filled: false)
                        }
                        .disabled(busy != nil)
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func countdownChip(_ offer: ClientPriorityOffer, expired: Bool) -> some View {
        if expired {
            Text("Expired")
                .font(BrandFont.mono(11))
                .foregroundStyle(BrandColor.textMuted)
                .padding(.vertical, 5).padding(.horizontal, 10)
                .background(BrandColor.textMuted.opacity(0.12))
                .clipShape(Capsule())
        } else if let remaining = offer.remaining(now: now) {
            let urgent = offer.isUrgent(now: now)
            Text(ClientPriorityOffer.countdownLabel(remaining))
                .font(BrandFont.mono(12))
                .foregroundStyle(urgent ? BrandColor.ember : BrandColor.textPrimary)
                .padding(.vertical, 5).padding(.horizontal, 10)
                .background((urgent ? BrandColor.ember : BrandColor.textPrimary).opacity(0.12))
                .clipShape(Capsule())
        }
    }

    // MARK: - Waitlist offer card

    private func waitlistCard(_ offer: ClientWaitlistOffer) -> some View {
        BrandSurface(tint: BrandColor.accent.opacity(0.06)) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    BrandAvatar(name: offer.proName, avatarUrl: offer.avatarUrl, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(offer.serviceLabel)
                            .font(BrandFont.body(15.5, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                            .lineLimit(1)
                        Text(subtitleLine(proName: offer.proName, startAt: offer.startAt, timeZone: offer.timeZone))
                            .font(BrandFont.body(12.5))
                            .foregroundStyle(BrandColor.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if busy == offer.offerId {
                        ProgressView().tint(BrandColor.accent).scaleEffect(0.8)
                    }
                }

                HStack(spacing: 10) {
                    Button { Task { await confirmWaitlist(offer) } } label: {
                        actionLabel("Confirm", filled: true)
                    }
                    .disabled(busy != nil)
                    Button { Task { await declineWaitlist(offer) } } label: {
                        actionLabel("Decline", filled: false)
                    }
                    .disabled(busy != nil)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Shared pieces

    private func actionLabel(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(BrandFont.body(13, filled ? .bold : .semibold))
            .foregroundStyle(filled ? BrandColor.onAccent : BrandColor.textMuted)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(filled ? BrandColor.accent : Color.clear)
            .overlay(
                Capsule().stroke(BrandColor.textPrimary.opacity(filled ? 0 : 0.16), lineWidth: 1)
            )
            .clipShape(Capsule())
    }

    private func subtitleLine(proName: String, startAt: String, timeZone: String?) -> String {
        let time = Wire.dateTime(startAt, timeZone: timeZone)
        return time.isEmpty ? proName : "\(proName) · \(time)"
    }

    private func sortedPriority(_ offers: [ClientPriorityOffer]) -> [ClientPriorityOffer] {
        guard let highlight = highlightRecipientId else { return offers }
        return offers.filter { $0.recipientId == highlight } + offers.filter { $0.recipientId != highlight }
    }

    // MARK: - Actions

    /// Claim: accept the priority window, then open the opening's own claim sheet —
    /// the same two-step the web "Claim it" does (accept → route to
    /// /offerings/{id}?scheduledFor=…, which is a fixed one-button page, NOT a
    /// picker). Falls back to the pro's profile when the opening can't be resolved.
    ///
    /// This deliberately never opens BookingFlowView. An opening is ONE time and
    /// `finalize` refuses any other minute with OPENING_NOT_AVAILABLE, so a picker
    /// here offers a choice that cannot succeed — and the accept above has already
    /// spent the exclusive window by the time it appears. See
    /// `ClientPriorityOffer.claimableOpening` and ClaimOpeningView's header (#180).
    private func claim(_ offer: ClientPriorityOffer) async {
        guard busy == nil else { return }
        busy = offer.recipientId
        defer { busy = nil }
        do {
            try await session.client.home.acceptInvite(recipientId: offer.recipientId)
        } catch let error as APIError {
            // Expired / no-longer-priority — surface it and refresh the list.
            actionError = error.userMessage
            await load()
            return
        } catch {
            actionError = "This offer is no longer available."
            await load()
            return
        }

        guard let professionalId = offer.professionalId else { await load(); return }

        // Accepting flipped the row PRIORITY_OFFERED → CLICKED, which is exactly
        // what admits it to the openings feed (that feed excludes PRIORITY_OFFERED),
        // so the full opening — its instant, price, place and incentive — is
        // readable now and was not a moment ago. Scoped to this pro to keep the
        // list small.
        do {
            let openings = try await session.client.home.openings(professionalId: professionalId)
            if let opening = offer.claimableOpening(in: openings) {
                claimTarget = ClaimTarget(opening: opening)
                return
            }
        } catch {
            // Fall through — an unresolvable opening lands on the pro, never on a
            // picker that cannot succeed.
        }
        proNav = ProNav(id: professionalId, name: offer.proName)
    }

    /// Land the client on the booking their claim just created (mirrors
    /// OpeningsFeedView), and refresh so the claimed offer leaves the list.
    ///
    /// If the booking read fails the claim has still SUCCEEDED, so this must not
    /// report an error. OpeningsFeedView shows a "You're booked" alert here; this
    /// screen deliberately does not, because it already owns one `.alert` and a
    /// second presentation modifier on the same view shadows the first — the
    /// regression #175 shipped and #176 fixed. The reload is the feedback: the
    /// claimed offer leaves the list because the server marked it BOOKED.
    private func openClaimedBooking(_ bookingId: String) async {
        session.signalRefresh()
        if let booking = try? await session.client.bookings.booking(id: bookingId) {
            bookingNav = ClientBookingNav(booking: booking)
        }
        await load()
    }

    private func pass(_ offer: ClientPriorityOffer) async {
        guard busy == nil else { return }
        busy = offer.recipientId
        defer { busy = nil }
        do {
            try await session.client.home.declineInvite(recipientId: offer.recipientId)
        } catch let error as APIError {
            actionError = error.userMessage
        } catch {
            actionError = "Could not pass on this offer."
        }
        await load()
    }

    private func confirmWaitlist(_ offer: ClientWaitlistOffer) async {
        guard busy == nil else { return }
        busy = offer.offerId
        defer { busy = nil }
        do {
            let booked = try await session.client.bookings.respondToWaitlistOffer(offerId: offer.offerId, confirm: true)
            if let booked, let booking = try await session.client.bookings.booking(id: booked.id) {
                bookingNav = ClientBookingNav(booking: booking)
                session.signalRefresh()
            } else {
                await load()
            }
        } catch let error as APIError {
            actionError = error.userMessage
            await load()
        } catch {
            actionError = "That time is no longer available."
            await load()
        }
    }

    private func declineWaitlist(_ offer: ClientWaitlistOffer) async {
        guard busy == nil else { return }
        busy = offer.offerId
        defer { busy = nil }
        do {
            _ = try await session.client.bookings.respondToWaitlistOffer(offerId: offer.offerId, confirm: false)
        } catch let error as APIError {
            actionError = error.userMessage
        } catch {
            actionError = "Could not decline this offer."
        }
        await load()
    }

    // MARK: - Load

    private func load() async {
        // The waitlist feed is best-effort (the priority list still renders if it
        // fails), mirroring the web WaitlistOfferCards' non-fatal load.
        let waitlist = (try? await session.client.bookings.waitlistOffers()) ?? []
        do {
            let priority = try await session.client.home.priorityOffers()
            phase = .loaded(priority: priority, waitlist: waitlist)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your offers.")
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
