// Client home — the first signed-in screen.
// Reads GET /api/v1/client/home via TovisKit's HomeService and renders the same
// data the web home page uses. Brand styling matches the login surface.
import SwiftUI
import TovisKit

struct HomeView: View {
    @Environment(SessionModel.self) private var session

    /// Jump to the Appointments tab (the home's appointment/action cards link here).
    var onOpenAppointments: () -> Void = {}

    private enum Phase {
        case loading
        case loaded(ClientHome)
        case failed(String)
    }

    @State private var phase: Phase = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                switch phase {
                case .loading:
                    loadingState
                case let .failed(message):
                    errorState(message)
                case let .loaded(home):
                    content(home)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .refreshable { await load() }
        .task {
            if case .loading = phase { await load() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                TovisEye(size: 30)
                Text("tovis")
                    .font(BrandFont.display(24, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
            }
            Spacer()
            Menu {
                if let email = session.currentUser?.email {
                    Text(email)
                }
                Button(role: .destructive) {
                    Task { await session.logout() }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 26))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func content(_ home: ClientHome) -> some View {
        if let action = home.action {
            Button(action: onOpenAppointments) { ActionBanner(action: action) }
                .buttonStyle(.plain)
        }

        if let upcoming = home.upcoming {
            BrandSection(title: "Next appointment", trailing: upcomingTrailing(home.upcomingCount)) {
                Button(action: onOpenAppointments) { UpcomingCard(booking: upcoming) }
                    .buttonStyle(.plain)
            }
        }

        if !home.invites.isEmpty {
            BrandSection(title: "Last-minute openings") {
                VStack(spacing: 10) {
                    ForEach(home.invites) { InviteRow(invite: $0) }
                }
            }
        }

        if !home.waitlists.isEmpty {
            BrandSection(title: "On your waitlist") {
                VStack(spacing: 10) {
                    ForEach(home.waitlists) { WaitlistRow(entry: $0) }
                }
            }
        }

        if !home.favoritePros.isEmpty {
            BrandSection(title: "Your pros") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(Array(home.favoritePros.enumerated()), id: \.offset) { _, fav in
                            if let pro = fav.professional { FavoriteProChip(pro: pro) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        if !home.favoriteServices.isEmpty {
            BrandSection(title: "Saved services") {
                VStack(spacing: 10) {
                    ForEach(home.favoriteServices) { fav in
                        if let service = fav.service { FavoriteServiceRow(service: service) }
                    }
                }
            }
        }

        let viral = home.viralLive + home.viralPending
        if !viral.isEmpty {
            BrandSection(title: "Trending looks") {
                VStack(spacing: 10) {
                    ForEach(viral) { ViralRow(look: $0) }
                }
            }
        }

        if isEmpty(home) {
            emptyState
        }
    }

    private func upcomingTrailing(_ count: Int) -> String? {
        count > 1 ? "\(count) upcoming" : nil
    }

    private func isEmpty(_ home: ClientHome) -> Bool {
        home.action == nil && home.upcoming == nil && home.invites.isEmpty &&
            home.waitlists.isEmpty && home.favoritePros.isEmpty &&
            home.favoriteServices.isEmpty && home.viralLive.isEmpty && home.viralPending.isEmpty
    }

    // MARK: - States

    private var loadingState: some View {
        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
            .padding(.top, 80)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Welcome to Tovis")
                .font(BrandFont.display(20, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("Discover pros and book your first appointment.")
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await load() }
            } label: {
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
        .padding(.top, 70)
    }

    // MARK: - Load

    private func load() async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            let home = try await session.client.home.fetch()
            phase = .loaded(home)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Something went wrong. Please try again.")
        }
    }
}

// MARK: - Cards & rows

private struct ActionBanner: View {
    let action: HomeAction

    private var copy: (title: String, subtitle: String, icon: String) {
        switch action {
        case .pendingConsultation:
            return ("Review your consultation", "Your pro sent a plan to approve.", "checklist")
        case .aftercarePaymentDue:
            return ("Payment due", "Finish up your recent visit.", "creditcard")
        }
    }

    var body: some View {
        BrandSurface(tint: BrandColor.accent.opacity(0.14)) {
            HStack(spacing: 12) {
                Image(systemName: copy.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(BrandColor.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(copy.title)
                        .font(BrandFont.body(16, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(copy.subtitle)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }
}

private struct UpcomingCard: View {
    let booking: HomeBooking

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                Text(booking.service?.name ?? "Appointment")
                    .font(BrandFont.body(17, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)

                if let pro = booking.professional {
                    Text("with \(pro.displayName)")
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textSecondary)
                }

                Label(Wire.dateTime(booking.scheduledFor, timeZone: booking.resolvedTimeZone),
                      systemImage: "calendar")
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textSecondary)

                if let place = locationLine {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textMuted)
                }

                HStack(spacing: 10) {
                    BrandPill(text: "\(booking.totalDurationMinutes) min")
                    if let amount = Wire.money(booking.totalAmount) {
                        BrandPill(text: amount)
                    }
                    BrandPill(text: booking.status.capitalized, tint: statusTone(booking.status))
                }
                .padding(.top, 2)
            }
        }
    }

    private var locationLine: String? {
        if let loc = booking.location {
            if let city = loc.city, let state = loc.state { return "\(city), \(state)" }
            return loc.name ?? loc.formattedAddress
        }
        return booking.professional?.location
    }
}

private struct InviteRow: View {
    let invite: HomeInvite

    var body: some View {
        BrandSurface {
            HStack(spacing: 12) {
                BrandAvatar(name: invite.opening.professional.displayName,
                            avatarUrl: invite.opening.professional.avatarUrl, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(invite.opening.professional.displayName)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(Wire.dateTime(invite.opening.startAt, timeZone: invite.opening.timeZone))
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                Spacer()
                BrandPill(text: "Open", tint: BrandColor.gold)
            }
        }
    }
}

private struct WaitlistRow: View {
    let entry: HomeWaitlist

    var body: some View {
        BrandSurface {
            HStack(spacing: 12) {
                if let pro = entry.professional {
                    BrandAvatar(name: pro.displayName, avatarUrl: pro.avatarUrl, size: 40)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.service?.name ?? "Any service")
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    if let pro = entry.professional {
                        Text(pro.displayName)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                }
                Spacer()
                BrandPill(text: "Waitlisted", tint: BrandColor.iris)
            }
        }
    }
}

private struct FavoriteProChip: View {
    let pro: HomeProfessional

    var body: some View {
        VStack(spacing: 8) {
            BrandAvatar(name: pro.displayName, avatarUrl: pro.avatarUrl, size: 64)
            Text(pro.displayName)
                .font(BrandFont.body(12, .medium))
                .foregroundStyle(BrandColor.textSecondary)
                .lineLimit(1)
                .frame(width: 72)
        }
    }
}

private struct FavoriteServiceRow: View {
    let service: HomeFavoriteServiceRef

    var body: some View {
        BrandSurface {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(service.name)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text("\(service.defaultDurationMinutes) min")
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textMuted)
                }
                Spacer()
                if let price = Wire.money(service.minPrice) {
                    Text("from \(price)")
                        .font(BrandFont.body(14, .semibold))
                        .foregroundStyle(BrandColor.accent)
                }
            }
        }
    }
}

private struct ViralRow: View {
    let look: HomeViral

    var body: some View {
        BrandSurface {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16))
                    .foregroundStyle(BrandColor.gold)
                Text(look.name)
                    .font(BrandFont.body(15, .medium))
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer()
                if look.fanOutCount > 0 {
                    Text("\(look.fanOutCount)")
                        .font(BrandFont.mono(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
    }
}
