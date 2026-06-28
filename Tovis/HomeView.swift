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
        NavigationStack {
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
            .toolbar(.hidden, for: .navigationBar)  // home has its own header
            .refreshable { await load() }
            .task {
                if case .loading = phase { await load() }
            }
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(greeting)
                    .font(BrandFont.mono(11))
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(BrandColor.textMuted)
                Text("\(displayName).")
                    .font(BrandFont.display(34, .semibold).italic())
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

    /// Time-of-day greeting — mirrors the web's `ClientGreeting`.
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 18 { return "Good afternoon" }
        return "Good evening"
    }

    /// Best-effort first name from the signed-in email (the home payload carries
    /// no client name). e.g. "amara619@gmail.com" → "Amara".
    private var displayName: String {
        guard let email = session.currentUser?.email,
              let local = email.split(separator: "@").first else { return "Welcome back" }
        let token = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .first.map(String.init) ?? String(local)
        let letters = String(token.prefix(while: { !$0.isNumber }))
        let base = letters.isEmpty ? token : letters
        guard let first = base.first else { return "Welcome back" }
        return first.uppercased() + base.dropFirst()
    }

    @ViewBuilder
    private func content(_ home: ClientHome) -> some View {
        // Section order mirrors the web home's mobile (single-column) flow:
        // action → invites → upcoming → favorite pros → favorited services →
        // waitlist → viral.
        if let action = home.action {
            Button(action: onOpenAppointments) { ActionBanner(action: action) }
                .buttonStyle(.plain)
        }

        if !home.invites.isEmpty {
            BrandSection(title: "Last-minute openings") {
                VStack(spacing: 10) {
                    ForEach(home.invites) { invite in
                        InviteRow(invite: invite, onChanged: { await load() })
                    }
                }
            }
        }

        if let upcoming = home.upcoming {
            BrandSection(title: "Next booking", trailing: upcomingTrailing(home.upcomingCount)) {
                Button(action: onOpenAppointments) { UpcomingCard(booking: upcoming) }
                    .buttonStyle(.plain)
            }
        }

        if !home.favoritePros.isEmpty {
            BrandSection(title: "Favorite pros") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(Array(home.favoritePros.enumerated()), id: \.offset) { _, fav in
                            if let pro = fav.professional {
                                proLink(id: pro.id, name: pro.displayName) { FavoriteProChip(pro: pro) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        if !home.favoriteServices.isEmpty {
            BrandSection(title: "Favorited services", trailing: "\(home.favoriteServices.count)") {
                VStack(spacing: 10) {
                    ForEach(home.favoriteServices) { fav in
                        if let service = fav.service { FavoriteServiceRow(service: service) }
                    }
                }
            }
        }

        if !home.waitlists.isEmpty {
            BrandSection(title: "On the waitlist") {
                VStack(spacing: 10) {
                    ForEach(home.waitlists) { entry in
                        if let pro = entry.professional {
                            proLink(id: pro.id, name: pro.displayName) { WaitlistRow(entry: entry) }
                        } else {
                            WaitlistRow(entry: entry)
                        }
                    }
                }
            }
        }

        let viral = home.viralLive + home.viralPending
        if !viral.isEmpty {
            BrandSection(title: "Viral looks") {
                VStack(spacing: 10) {
                    ForEach(viral) { ViralRow(look: $0) }
                }
            }
        }

        if isEmpty(home) {
            emptyState
        }
    }

    /// Wrap a row in a navigation link to the pro's public profile.
    private func proLink<Label: View>(
        id: String, name: String, @ViewBuilder label: () -> Label
    ) -> some View {
        NavigationLink {
            ProProfileView(professionalId: id, fallbackName: name)
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }

    private func upcomingTrailing(_ count: Int) -> String? {
        count > 1 ? "\(count - 1) more" : nil
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
    @Environment(SessionModel.self) private var session
    let invite: HomeInvite
    /// Reload home after accept/decline so the offer leaves the list.
    var onChanged: () async -> Void

    @State private var working = false
    @State private var errorMessage: String?

    private var pro: HomeProfessional { invite.opening.professional }

    var body: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink {
                    ProProfileView(professionalId: pro.id, fallbackName: pro.displayName)
                } label: {
                    HStack(spacing: 12) {
                        BrandAvatar(name: pro.displayName, avatarUrl: pro.avatarUrl, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(pro.displayName)
                                .font(BrandFont.body(15, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                            Text(Wire.dateTime(invite.opening.startAt, timeZone: invite.opening.timeZone))
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }
                .buttonStyle(.plain)

                HStack(spacing: 10) {
                    Button { Task { await act(accept: true) } } label: {
                        actionLabel("Accept", filled: true)
                    }
                    .disabled(working)
                    Button { Task { await act(accept: false) } } label: {
                        actionLabel("Decline", filled: false)
                    }
                    .disabled(working)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.ember)
                }
            }
        }
    }

    private func actionLabel(_ title: String, filled: Bool) -> some View {
        Text(title)
            .font(BrandFont.body(14, .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(filled ? BrandColor.onAccent : BrandColor.textSecondary)
            .background(filled ? BrandColor.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(filled ? Color.clear : BrandColor.textMuted.opacity(0.3), lineWidth: 1)
            )
            .opacity(working ? 0.6 : 1)
    }

    private func act(accept: Bool) async {
        guard !working else { return }
        working = true
        errorMessage = nil
        do {
            if accept {
                try await session.client.home.acceptInvite(recipientId: invite.id)
            } else {
                try await session.client.home.declineInvite(recipientId: invite.id)
            }
            await onChanged()
        } catch let error as APIError {
            errorMessage = error.userMessage
            working = false
        } catch {
            errorMessage = "Something went wrong. Please try again."
            working = false
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
