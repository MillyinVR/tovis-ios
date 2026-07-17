// Client last-minute openings feed — the native counterpart to the web
// /client/openings page (app/client/(gated)/openings/OpeningsFeedClient.tsx),
// backed by GET /api/v1/client/openings. A list of freed-up slots the client is a
// recipient of; each card shows the service, pro, time, and a discounted price, and
// tapping it resolves the offering and opens the booking flow pre-seeded to that
// slot — the same destination as the web "Grab it →" link
// (/offerings/{id}?scheduledFor=…&openingId=…). Pushed inside the host tab's
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

    /// Booking-flow launch for a resolved offering (mirrors LooksView's `BookLaunch`),
    /// carrying the opening's slot so the sheet opens pre-seeded to that time.
    private struct BookLaunch: Identifiable {
        let professionalId: String
        let proName: String
        let offering: ProOffering
        let preselectedSlot: String
        /// The `LastMinuteOpening.id` (`ClientOpening.opening.id`) so finalize
        /// consumes the opening + applies its incentive (web parity).
        let openingId: String
        var id: String { offering.id + preselectedSlot }
    }

    /// Pro-profile fallback push when an opening's offering can't be resolved
    /// (inactive / no longer on the profile) — the client can still reach the pro.
    private struct ProNav: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @State private var phase: Phase = .loading
    @State private var bookLaunch: BookLaunch?
    @State private var proNav: ProNav?
    /// The opening (recipient id) currently resolving its offering, for a spinner.
    @State private var resolving: String?
    @State private var resolveError: String?

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
        .sheet(item: $bookLaunch) { launch in
            BookingFlowView(
                professionalId: launch.professionalId,
                proName: launch.proName,
                offering: launch.offering,
                preselectedSlot: launch.preselectedSlot,
                openingId: launch.openingId
            )
        }
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
        .onChange(of: session.refreshTick) { Task { await load() } }
        .alert("Couldn’t open that opening", isPresented: resolveErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try again in a moment.")
        }
    }

    private var resolveErrorBinding: Binding<Bool> {
        Binding(get: { resolveError != nil }, set: { if !$0 { resolveError = nil } })
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
            Task { await open(opening) }
        } label: {
            BrandSurface(tint: BrandColor.bgSecondary) {
                cardBody(opening)
            }
        }
        .buttonStyle(.plain)
        .disabled(resolving != nil)
    }

    private func cardBody(_ opening: ClientOpening) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if opening.matchedWaitlist {
                BrandPill(text: "✦ Matches your waitlist", tint: BrandColor.accent)
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
                if resolving == opening.id {
                    ProgressView().tint(BrandColor.accent).scaleEffect(0.8)
                } else {
                    Text("Grab it →")
                        .font(BrandFont.body(13, .bold))
                        .foregroundStyle(BrandColor.accent)
                }
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
            if let price = Wire.moneyDecimal(opening.finalPrice) {
                Text(price)
                    .font(BrandFont.body(18, .bold))
                    .foregroundStyle(BrandColor.accent)
            }
            if opening.hasDiscount, let label = opening.incentiveLabel {
                Text(label)
                    .font(BrandFont.body(9, .bold))
                    .foregroundStyle(BrandColor.gold)
            }
        }
    }

    // MARK: - Actions

    /// Resolve the opening's offering on the pro's profile, then open the booking
    /// flow pre-seeded to the slot. Falls back to the pro's profile when the offering
    /// can't be resolved (no service id / no longer offered), mirroring LooksView.
    private func open(_ opening: ClientOpening) async {
        guard resolving == nil else { return }
        guard let serviceId = opening.serviceId else {
            proNav = ProNav(id: opening.opening.professionalId, name: opening.proName)
            return
        }
        resolving = opening.id
        defer { resolving = nil }
        do {
            let profile = try await session.client.profiles.professional(id: opening.opening.professionalId)
            if let offering = profile.offerings.first(where: { $0.serviceId == serviceId }) {
                bookLaunch = BookLaunch(
                    professionalId: opening.opening.professionalId,
                    proName: opening.proName,
                    offering: offering,
                    preselectedSlot: opening.startAt,
                    openingId: opening.opening.id
                )
            } else {
                proNav = ProNav(id: opening.opening.professionalId, name: opening.proName)
            }
        } catch {
            resolveError = "failed"
        }
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
