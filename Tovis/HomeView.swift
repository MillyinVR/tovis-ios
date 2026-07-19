// Client home — the first signed-in screen, a native rebuild of the web client
// home (app/client/(gated)/_components/ClientHomeShell.tsx + its cards). Same
// sections in the same order: atmospheric glow + greeting header, then the
// action card, last-minute openings, next booking, favorite pros, favorited
// services, waitlist, and the Viral Looks band. Reads GET /api/v1/client/home.
import SwiftUI
import TovisKit

/// The copy the home surface falls back to when a booking carries no pro, or the
/// pro has no usable name token. Per-SURFACE by convention (see
/// `ProPublicDisplayName.publicDisplayName(fallback:)`) — but written once here
/// rather than welded into three separate expressions across two views.
private let homeProFallbackName = "Your pro"

struct HomeView: View {
    @Environment(SessionModel.self) private var session
    /// Two columns at regular width (iPad), single column on iPhone — mirrors the
    /// web shell's `grid-cols-1 md:grid-cols-2` (phones stay single-column).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Switch the shell to the Inbox tab (the header bell), set by MainTabView.
    var onOpenInbox: () -> Void = {}

    private enum Phase {
        case loading
        case loaded(ClientHome)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var showNotifications = false
    /// Drives the notifications-bell unread dot (GET .../notifications/summary).
    @State private var hasUnreadNotifications = false
    /// The client's referral invite link, backing the "Invite a friend" card
    /// (web InviteFriendCard). Loaded best-effort — the card is hidden if absent.
    @State private var inviteLink: ClientInviteLink?

    var body: some View {
        NavigationStack {
            ScrollView {
                ZStack(alignment: .top) {
                    glow
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        switch phase {
                        case .loading: loadingState
                        case let .failed(message): errorState(message)
                        case let .loaded(home): content(home)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 48)
                }
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await load() }
            .task { if case .loading = phase { await load() } }
            .onChange(of: session.refreshTick) { Task { await load() } }
            .task { await poll() }
            .sheet(isPresented: $showNotifications) { NotificationsView() }
        }
        .tint(BrandColor.accent)
    }

    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { await load() }
        }
    }

    /// Top accent glow — mirrors the web shell's two gradient layers.
    private var glow: some View {
        LinearGradient(
            colors: [BrandColor.accent.opacity(0.14), BrandColor.accent.opacity(0.03), .clear],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 300)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(greeting)
                    .font(BrandFont.mono(10)).tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(BrandColor.textMuted)
                Text("\(displayName).")
                    .font(BrandFont.display(34, .semibold).italic())
                    .foregroundStyle(BrandColor.textPrimary)
            }
            Spacer()
            HStack(spacing: 10) {
                notificationsBell
                inboxBell
            }
        }
        .padding(.top, 4)
    }

    /// Notification center entry — bell in a circle with an unread dot (driven by
    /// GET .../notifications/summary). Opens the NotificationsView sheet.
    private var notificationsBell: some View {
        Button(action: { showNotifications = true }) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                    .font(.system(size: 17))
                    .foregroundStyle(BrandColor.textMuted)
                    .frame(width: 38, height: 38)
                    .overlay(Circle().stroke(BrandColor.textPrimary.opacity(0.16), lineWidth: 1))
                if hasUnreadNotifications {
                    Circle()
                        .fill(BrandColor.gold)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(BrandColor.bgPrimary, lineWidth: 1.5))
                        .offset(x: -2, y: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Notifications")
    }

    /// Messages entry point — envelope in a circle (links to the Inbox tab).
    private var inboxBell: some View {
        Button(action: onOpenInbox) {
            Image(systemName: "envelope")
                .font(.system(size: 16))
                .foregroundStyle(BrandColor.textMuted)
                .frame(width: 38, height: 38)
                .overlay(Circle().stroke(BrandColor.textPrimary.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Messages")
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 18 { return "Good afternoon" }
        return "Good evening"
    }

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

    // MARK: - Loaded content (web section order + two-column at regular width)

    @ViewBuilder
    private func content(_ home: ClientHome) -> some View {
        if horizontalSizeClass == .regular {
            // Two side-by-side card stacks (web `md:grid-cols-2`): left = action /
            // last-minute / next booking; right = favorites / waitlist / invite.
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 20) { leftColumn(home) }
                VStack(alignment: .leading, spacing: 20) { rightColumn(home) }
            }
        } else {
            // iPhone: single column — left stack then right stack (web `grid-cols-1`).
            leftColumn(home)
            rightColumn(home)
        }

        ViralLooksBand(live: home.viralLive.first, pending: home.viralPending.first,
                       liveMore: max(0, home.viralLive.count - 1),
                       pendingMore: max(0, home.viralPending.count - 1),
                       onSubmitted: { await load() })
            .padding(.top, 6)
    }

    @ViewBuilder
    private func leftColumn(_ home: ClientHome) -> some View {
        if let action = home.action {
            ActionCard(action: action, onChanged: { await load() })
        }
        InvitesCard(invites: home.invites, onChanged: { await load() })
        UpcomingCard(booking: home.upcoming, upcomingCount: home.upcomingCount)
    }

    @ViewBuilder
    private func rightColumn(_ home: ClientHome) -> some View {
        if !home.favoritePros.isEmpty {
            FavoriteProsCard(favoritePros: home.favoritePros)
        }
        if !home.favoriteServices.isEmpty {
            FavoritedServicesCard(services: home.favoriteServices)
        }
        WaitlistCard(waitlists: home.waitlists)
        if let inviteLink {
            ClientInviteCard(invite: inviteLink)
        }
    }

    // MARK: - States

    private var loadingState: some View {
        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
            .padding(.top, 80)
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
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    private func load() async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            phase = .loaded(try await session.client.home.fetch())
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Something went wrong. Please try again.")
        }
        await loadNotificationSummary()
        // Best-effort: the invite card is hidden until this resolves, never blocks.
        if inviteLink == nil {
            inviteLink = try? await session.client.referrals.inviteLink()
        }
    }

    /// Best-effort unread-notifications check for the bell dot — never blocks or
    /// fails the home load. Uses the unread feed (covers every event type, unlike
    /// the bucketed summary) and only needs to know whether ANY exist.
    private func loadNotificationSummary() async {
        if let page = try? await session.client.notifications.feed(unreadOnly: true, take: 1) {
            hasUnreadNotifications = !page.items.isEmpty
        }
    }
}

// MARK: - Shared building blocks

/// A home card surface — rounded, hairline border, surface fill (web "rounded-card
/// border border-textPrimary/10 bg-bgSurface p-[18px]").
private struct HomeCard<Content: View>: View {
    var accentEdge: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BrandColor.bgSurface)
            .overlay(alignment: .leading) {
                if let accentEdge {
                    Rectangle().fill(accentEdge).frame(width: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(BrandColor.textPrimary.opacity(0.10), lineWidth: 1)
            )
    }
}

/// mono-uppercase eyebrow label used across the home sections.
private struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(BrandFont.mono(10)).tracking(1.6)
            .foregroundStyle(BrandColor.textMuted)
    }
}

/// A small pill (outlined or filled), matching the web status chips.
private struct Pill: View {
    let text: String
    var color: Color = BrandColor.accent
    var filled: Bool = false

    var body: some View {
        Text(text.uppercased())
            .font(BrandFont.mono(9.5)).tracking(1.2)
            .foregroundStyle(filled ? BrandColor.onAccent : color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(filled ? color : color.opacity(0.14))
            .clipShape(Capsule())
            .overlay(filled ? nil : Capsule().stroke(color, lineWidth: 1))
    }
}

/// Radial brand-gradient fill for image-less avatars (web gradientAvatar).
private func gradientAvatar(_ index: Int) -> LinearGradient {
    let pairs: [(Color, Color)] = [
        (BrandColor.accent, BrandColor.iris),
        (BrandColor.accentHover, BrandColor.accent),
        (BrandColor.gold, BrandColor.emerald),
        (BrandColor.iris, BrandColor.accentHover),
    ]
    let (a, b) = pairs[((index % pairs.count) + pairs.count) % pairs.count]
    return LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// A gradient/initials avatar that loads a remote image when present.
private struct GradientAvatar: View {
    let name: String
    let url: String?
    var index: Int = 0
    var size: CGFloat = 38
    var corner: CGFloat = 11

    var body: some View {
        ZStack {
            gradientAvatar(index)
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            } else {
                Text(initials)
                    .font(BrandFont.body(size * 0.32, .bold))
                    .foregroundStyle(BrandColor.onAccent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "·" : s.uppercased()
    }
}

private func formatDuration(_ minutes: Int) -> String? {
    guard minutes > 0 else { return nil }
    let h = minutes / 60, m = minutes % 60
    if h == 0 { return "\(m)m" }
    if m == 0 { return "\(h)h" }
    return "\(h)h \(m)m"
}

// MARK: - Action card

private struct ActionCard: View {
    @Environment(SessionModel.self) private var session
    let action: HomeAction
    var onChanged: () async -> Void

    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        switch action {
        case let .pendingConsultation(booking):
            pendingConsultation(booking)
        case let .aftercarePaymentDue(booking, aftercare):
            aftercarePayment(booking, aftercare)
        }
    }

    private func pendingConsultation(_ booking: HomeBooking) -> some View {
        let proName = booking.professional?.displayName ?? homeProFallbackName
        let proFirst = proName.split(separator: " ").first.map(String.init)
            ?? homeProFallbackName
        let proposed = Wire.money(booking.consultationApproval?.proposedTotal)
        let was = Wire.money(booking.totalAmount)
        let notes = booking.consultationApproval?.notes?.trimmingCharacters(in: .whitespacesAndNewlines)

        return HomeCard(accentEdge: BrandColor.gold) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    iconChip("checklist", tint: BrandColor.gold)
                    Pill(text: "Action needed", color: BrandColor.gold)
                    Spacer()
                }
                Text("\(proFirst) sent a consultation to review")
                    .font(BrandFont.display(18, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text(notes?.isEmpty == false ? notes! :
                        "Your pro reviewed your details and proposed an updated plan. Approve it before your booking.")
                    .font(BrandFont.body(13.5))
                    .foregroundStyle(BrandColor.textSecondary)

                if let proposed {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("New total").font(BrandFont.body(13, .bold)).foregroundStyle(BrandColor.textPrimary)
                            if let was { Text("Was \(was)").font(BrandFont.mono(10)).foregroundStyle(BrandColor.textMuted) }
                        }
                        Spacer()
                        Text(proposed).font(BrandFont.display(22, .bold)).foregroundStyle(BrandColor.gold)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(BrandColor.textPrimary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(BrandColor.textPrimary.opacity(0.10), lineWidth: 1))
                }

                Button { Task { await decide(.approve, bookingId: booking.id) } } label: {
                    primaryLabel("Review & approve →")
                }
                .disabled(working)

                Button { Task { await decide(.reject, bookingId: booking.id) } } label: {
                    Text(was != nil ? "Decline · keep my \(was!) booking" : "Decline")
                        .font(BrandFont.body(12.5, .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                        .frame(maxWidth: .infinity)
                }
                .disabled(working)

                if let errorMessage {
                    Text(errorMessage).font(BrandFont.body(12)).foregroundStyle(BrandColor.ember)
                }
            }
        }
    }

    private func aftercarePayment(_ booking: HomeBooking, _ aftercare: HomeAftercare) -> some View {
        let title = booking.service?.name ?? "Your visit"
        let due = Wire.money(booking.totalAmount)
        let proName = booking.professional?.displayName ?? "your pro"
        let notes = aftercare.notes?.trimmingCharacters(in: .whitespacesAndNewlines)

        return NavigationLink { AftercareInboxView() } label: {
            HomeCard(accentEdge: BrandColor.ember) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        iconChip("doc.text", tint: BrandColor.ember)
                        Pill(text: "Summary ready", color: BrandColor.ember)
                        if let due { Pill(text: "\(due) due", color: BrandColor.gold, filled: false) }
                        Spacer()
                    }
                    Text("Your aftercare summary is ready")
                        .font(BrandFont.display(18, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(notes?.isEmpty == false ? notes! :
                            "Before & after, care notes, and your receipt are waiting.")
                        .font(BrandFont.body(13.5))
                        .foregroundStyle(BrandColor.textSecondary)
                    Text("\(title) with \(proName)")
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(BrandColor.textPrimary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    primaryLabel(due != nil ? "View summary & pay \(due!) →" : "View summary →")
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func iconChip(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(tint.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func primaryLabel(_ text: String) -> some View {
        Text(text)
            .font(BrandFont.body(15, .semibold))
            .foregroundStyle(BrandColor.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(BrandColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(working ? 0.6 : 1)
    }

    private func decide(_ decision: ConsultationDecision, bookingId: String) async {
        guard !working else { return }
        working = true; errorMessage = nil
        do {
            try await session.client.bookings.decideConsultation(bookingId: bookingId, decision)
            await onChanged()
        } catch let error as APIError {
            errorMessage = error.userMessage; working = false
        } catch {
            errorMessage = "Something went wrong. Please try again."; working = false
        }
    }
}

// MARK: - Last-minute openings

private struct InvitesCard: View {
    @Environment(SessionModel.self) private var session
    let invites: [HomeInvite]
    var onChanged: () async -> Void

    var body: some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill").font(.system(size: 12)).foregroundStyle(BrandColor.gold)
                    Eyebrow(text: "Last-minute openings")
                    Spacer()
                    NavigationLink { OpeningsFeedView() } label: {
                        Text("See all")
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(BrandColor.accent)
                    }
                    .buttonStyle(.plain)
                }
                if invites.isEmpty {
                    Text("No last-minute openings right now. We’ll ping you the moment a pro opens a spot.")
                        .font(BrandFont.body(12.5)).foregroundStyle(BrandColor.textMuted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(invites.prefix(5).enumerated()), id: \.element.id) { idx, invite in
                            InviteRow(invite: invite, index: idx, onChanged: onChanged)
                            if idx < min(invites.count, 5) - 1 {
                                Divider().overlay(BrandColor.textPrimary.opacity(0.10))
                            }
                        }
                    }

                    // The full claim surface — priority offers with live countdowns
                    // + any pro-proposed waitlist times (the /client/offers page).
                    NavigationLink { PriorityOffersView() } label: {
                        HStack(spacing: 4) {
                            Text("Your priority offers")
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                        .font(BrandFont.body(12.5, .semibold))
                        .foregroundStyle(BrandColor.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct InviteRow: View {
    @Environment(SessionModel.self) private var session
    let invite: HomeInvite
    let index: Int
    var onChanged: () async -> Void

    @State private var working = false
    @State private var errorMessage: String?

    private var pro: HomeProfessional { invite.opening.professional }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                ProProfileView(professionalId: pro.id, fallbackName: pro.displayName)
            } label: {
                HStack(spacing: 12) {
                    GradientAvatar(name: pro.displayName, url: pro.avatarUrl, index: index, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("\(pro.displayName.split(separator: " ").first.map(String.init) ?? pro.displayName) · \(invite.opening.title)")
                                .font(BrandFont.body(13.5, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                                .lineLimit(1)
                            // The offer, right beside the service and bigger than
                            // the line it sits on. This card is the FIRST place a
                            // client sees a last-minute opening, and the incentive
                            // — not a starting price the pro hasn't finalised — is
                            // what makes it worth acting on.
                            if let headline = invite.opening.incentiveHeadline {
                                Text(headline)
                                    .font(BrandFont.body(14, .bold))
                                    .foregroundStyle(BrandColor.onAccent)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(BrandColor.accent)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                        Text(metaLine)
                            .font(BrandFont.body(11.5))
                            .foregroundStyle(BrandColor.textMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Button { Task { await act(accept: true) } } label: {
                    Text("Grab it")
                        .font(BrandFont.body(12, .bold))
                        .foregroundStyle(BrandColor.onAccent)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(BrandColor.accent)
                        .clipShape(Capsule())
                }.disabled(working)
                Button { Task { await act(accept: false) } } label: {
                    Text("Pass")
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .overlay(Capsule().stroke(BrandColor.textPrimary.opacity(0.16), lineWidth: 1))
                }.disabled(working)
                Spacer()
            }
            if let errorMessage {
                Text(errorMessage).font(BrandFont.body(11.5)).foregroundStyle(BrandColor.ember)
            }
        }
        .padding(.vertical, 10)
        .opacity(working ? 0.6 : 1)
    }

    private var metaLine: String {
        let time = Wire.dateTime(invite.opening.startAt, timeZone: invite.opening.timeZone)
        // "From", because the field is a STARTING price — the pro sets the final
        // one at the consultation. (The wire even names it `startingPrice`.)
        let price = invite.opening.startingPrice
            .flatMap { Wire.money($0) }
            .map { "From \($0)" }
        let parts = [time, pro.location, price]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    private func act(accept: Bool) async {
        guard !working else { return }
        working = true; errorMessage = nil
        do {
            if accept {
                try await session.client.home.acceptInvite(recipientId: invite.id)
            } else {
                try await session.client.home.declineInvite(recipientId: invite.id)
            }
            await onChanged()
        } catch let error as APIError {
            errorMessage = error.userMessage; working = false
        } catch {
            errorMessage = "Something went wrong. Please try again."; working = false
        }
    }
}

// MARK: - Next booking

private struct UpcomingCard: View {
    let booking: HomeBooking?
    let upcomingCount: Int

    var body: some View {
        if let booking {
            NavigationLink { AppointmentsView() } label: { card(booking) }
                .buttonStyle(.plain)
        } else {
            empty
        }
    }

    private func card(_ booking: HomeBooking) -> some View {
        let pro = booking.professional
        let total = Wire.money(booking.totalAmount)
        let when = Wire.dateTime(booking.scheduledFor, timeZone: booking.resolvedTimeZone)
        let duration = formatDuration(booking.totalDurationMinutes)
        let location = booking.location?.name ?? booking.location?.city ?? pro?.location
        let more = max(0, upcomingCount - 1)

        return HomeCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Eyebrow(text: "Next booking")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(BrandColor.accent).frame(width: 6, height: 6)
                        Text("CONFIRMED").font(BrandFont.mono(10)).tracking(1.0).foregroundStyle(BrandColor.accent)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .overlay(Capsule().stroke(BrandColor.accent, lineWidth: 1))
                }

                HStack(spacing: 12) {
                    GradientAvatar(name: pro?.displayName ?? "Pro", url: pro?.avatarUrl, size: 44, corner: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pro?.displayName ?? homeProFallbackName)
                            .font(BrandFont.body(17, .semibold)).foregroundStyle(BrandColor.textPrimary)
                            .lineLimit(1)
                        if let location {
                            Text(location).font(BrandFont.body(12.5)).foregroundStyle(BrandColor.textMuted).lineLimit(1)
                        }
                    }
                    Spacer()
                }

                VStack(spacing: 10) {
                    HStack {
                        Text(booking.service?.name ?? "Appointment")
                            .font(BrandFont.body(14.5, .semibold)).foregroundStyle(BrandColor.textPrimary)
                        Spacer()
                        if let total { Text(total).font(BrandFont.display(14, .semibold)).foregroundStyle(BrandColor.accent) }
                    }
                    HStack {
                        Text(when).font(BrandFont.mono(11)).foregroundStyle(BrandColor.textMuted).lineLimit(1)
                        Spacer()
                        if let duration { Text(duration).font(BrandFont.mono(11)).foregroundStyle(BrandColor.textMuted) }
                    }
                }
                .padding(.top, 14)
                .overlay(alignment: .top) {
                    Rectangle().fill(BrandColor.textPrimary.opacity(0.10)).frame(height: 1)
                }

                if more > 0 {
                    Text("\(more) more upcoming →")
                        .font(BrandFont.body(12.5, .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var empty: some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Next booking")
                Text("No approved bookings yet.")
                    .font(BrandFont.body(13, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("When a pro approves your booking, it’ll show up here.")
                    .font(BrandFont.body(11.5)).foregroundStyle(BrandColor.textMuted)
            }
        }
    }
}

// MARK: - Favorite pros

private struct FavoriteProsCard: View {
    let favoritePros: [HomeFavoritePro]

    private var pros: [HomeProfessional] {
        favoritePros.compactMap { $0.professional }.prefix(6).map { $0 }
    }

    var body: some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "Favorite pros · \(favoritePros.count)")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)], spacing: 11) {
                    ForEach(pros) { pro in
                        NavigationLink {
                            ProProfileView(professionalId: pro.id, fallbackName: pro.displayName)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                GradientAvatar(name: pro.displayName, url: pro.avatarUrl, size: 40, corner: 20)
                                Text(pro.displayName)
                                    .font(BrandFont.body(13.5, .semibold)).foregroundStyle(BrandColor.textPrimary)
                                    .lineLimit(1)
                                if let craft = pro.professionType {
                                    Text(craft.capitalized).font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted).lineLimit(1)
                                }
                                Text("Book")
                                    .font(BrandFont.body(11.5, .bold)).foregroundStyle(BrandColor.onAccent)
                                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                                    .background(BrandColor.accent).clipShape(Capsule())
                                    .padding(.top, 2)
                            }
                            .padding(13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(BrandColor.textPrimary.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .stroke(BrandColor.textPrimary.opacity(0.10), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Favorited services

private struct FavoritedServicesCard: View {
    let services: [HomeFavoriteService]

    var body: some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "Favorited services · \(services.count)")
                VStack(spacing: 0) {
                    let rows = Array(services.prefix(5).enumerated())
                    ForEach(rows, id: \.element.id) { idx, fav in
                        if let service = fav.service {
                            row(service, index: idx)
                            if idx < rows.count - 1 { Divider().overlay(BrandColor.textPrimary.opacity(0.10)) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ service: HomeFavoriteServiceRef, index: Int) -> some View {
        let tints = [BrandColor.accent, BrandColor.gold, BrandColor.iris]
        let tint = tints[index % tints.count]
        let meta = [service.category?.name,
                    Wire.money(service.minPrice).map { "from \($0)" },
                    formatDuration(service.defaultDurationMinutes)]
            .compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 12) {
            ZStack {
                tint.opacity(0.15)
                if let url = service.defaultImageUrl, let parsed = URL(string: url) {
                    AsyncImage(url: parsed) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                } else {
                    Image(systemName: "heart.fill").font(.system(size: 14)).foregroundStyle(tint)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(service.name).font(BrandFont.body(14, .semibold)).foregroundStyle(BrandColor.textPrimary).lineLimit(1)
                Text(meta).font(BrandFont.body(11.5)).foregroundStyle(BrandColor.textMuted).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Waitlist

private struct WaitlistCard: View {
    let waitlists: [HomeWaitlist]

    var body: some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Eyebrow(text: "On the waitlist")
                    Spacer()
                    if !waitlists.isEmpty {
                        Text("\(waitlists.count) active").font(BrandFont.mono(10)).foregroundStyle(BrandColor.textMuted)
                    }
                }
                if waitlists.isEmpty {
                    Text("You’re not on any waitlists. Join one and we’ll hold your place here.")
                        .font(BrandFont.body(12.5)).foregroundStyle(BrandColor.textMuted)
                } else {
                    VStack(spacing: 0) {
                        let rows = Array(waitlists.prefix(6).enumerated())
                        ForEach(rows, id: \.element.id) { idx, entry in
                            row(entry, index: idx)
                            if idx < rows.count - 1 { Divider().overlay(BrandColor.textPrimary.opacity(0.10)) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: HomeWaitlist, index: Int) -> some View {
        let content = HStack(spacing: 12) {
            GradientAvatar(name: entry.professional?.displayName ?? "Pro",
                           url: entry.professional?.avatarUrl, index: index, size: 36, corner: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.service?.name ?? "Service")
                    .font(BrandFont.body(13.5, .semibold)).foregroundStyle(BrandColor.textPrimary).lineLimit(1)
                if let pro = entry.professional {
                    Text("with \(pro.displayName)").font(BrandFont.body(11.5)).foregroundStyle(BrandColor.textMuted).lineLimit(1)
                }
            }
            Spacer()
            Text("#\(index + 1) IN LINE")
                .font(BrandFont.mono(10)).tracking(0.6).foregroundStyle(BrandColor.accent)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(BrandColor.accent.opacity(0.10)).clipShape(Capsule())
        }
        .padding(.vertical, 10)

        if let pro = entry.professional {
            NavigationLink { ProProfileView(professionalId: pro.id, fallbackName: pro.displayName) } label: { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

// MARK: - Viral Looks band

private struct ViralLooksBand: View {
    let live: HomeViral?
    let pending: HomeViral?
    let liveMore: Int
    let pendingMore: Int
    /// Refreshes home after a submit so the new request appears in `pendingHero`.
    var onSubmitted: () async -> Void = {}

    @State private var showSubmit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill").font(.system(size: 12)).foregroundStyle(BrandColor.gold)
                    Eyebrow(text: "New tab in your Looks feed")
                }
                Text("Viral Looks")
                    .font(BrandFont.display(26, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("Spot a look blowing up online? We get it named, vetted, and matched to pros who actually do it — so you can book the exact viral look.")
                    .font(BrandFont.body(14)).foregroundStyle(BrandColor.textSecondary)
            }
            .padding(.top, 24)
            .overlay(alignment: .top) { Rectangle().fill(BrandColor.textPrimary.opacity(0.10)).frame(height: 1) }

            // Web's band is a three-cell grid: live, pending, submit — each cell
            // always present, each with its own empty state.
            if let live { liveHero(live) } else { liveEmpty }
            if let pending { pendingHero(pending) } else { pendingEmpty }
            submitCard
        }
        .sheet(isPresented: $showSubmit) {
            SubmitViralLookView(onSubmitted: onSubmitted)
        }
    }

    private func liveHero(_ look: HomeViral) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [BrandColor.accent.opacity(0.55), BrandColor.bgPrimary],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HStack(spacing: 6) {
                        Circle().fill(BrandColor.ember).frame(width: 6, height: 6)
                        Text("LIVE NOW").font(BrandFont.mono(9.5)).tracking(1.4).foregroundStyle(BrandColor.textPrimary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(BrandColor.bgPrimary.opacity(0.5)).clipShape(Capsule())
                    .overlay(Capsule().stroke(BrandColor.ember.opacity(0.55), lineWidth: 1))
                    Spacer()
                    if let platform = look.platform {
                        Text("via \(platform)").font(BrandFont.mono(9.5)).tracking(1.0)
                            .foregroundStyle(BrandColor.textSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(BrandColor.bgPrimary.opacity(0.5)).clipShape(Capsule())
                    }
                }
                Spacer()
                Eyebrow(text: "Trending this week")
                Text(look.name)
                    .font(BrandFont.display(25, .bold)).foregroundStyle(BrandColor.textPrimary)
                Text(look.fanOutCount > 0
                     ? "\(look.fanOutCount) \(look.fanOutCount == 1 ? "pro" : "pros") now offer this"
                     : "Newly approved — pros are picking it up now.")
                    .font(BrandFont.body(12)).foregroundStyle(BrandColor.textSecondary)
                if liveMore > 0 {
                    Text("+\(liveMore) more live in the feed →")
                        .font(BrandFont.body(12, .semibold)).foregroundStyle(BrandColor.textSecondary)
                        .padding(.top, 2)
                }
            }
            .padding(16)
        }
        .frame(minHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(BrandColor.textPrimary.opacity(0.10), lineWidth: 1))
    }

    private var liveEmpty: some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Live now")
                Text("No viral looks live yet")
                    .font(BrandFont.display(20, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("Be the first — submit a look you’re seeing everywhere and we’ll get it named, vetted, and matched to pros.")
                    .font(BrandFont.body(12.5)).foregroundStyle(BrandColor.textSecondary)
            }
        }
    }

    private func pendingHero(_ look: HomeViral) -> some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Pill(text: "Pending", color: BrandColor.gold)
                    Spacer()
                    if let platform = look.platform {
                        Text("via \(platform)").font(BrandFont.mono(9.5)).tracking(1.0).foregroundStyle(BrandColor.textMuted)
                    }
                }
                Eyebrow(text: "Your request")
                Text(look.name)
                    .font(BrandFont.display(21, .bold)).foregroundStyle(BrandColor.textPrimary)
                pipeline(status: look.status)
                Text(look.fanOutCount > 0
                     ? "Shared with \(look.fanOutCount) \(look.fanOutCount == 1 ? "pro" : "pros") in your area. We’ll notify you the moment it’s bookable."
                     : "In review with our team. We’ll share it with pros and notify you the moment it’s bookable.")
                    .font(BrandFont.body(12.5)).foregroundStyle(BrandColor.textSecondary)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(BrandColor.textPrimary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if pendingMore > 0 {
                    Text("\(pendingMore) more pending")
                        .font(BrandFont.display(12, .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    /// Web's PendingLookEmpty — the third state the band needs, and the one every
    /// client sees before their first submission.
    private var pendingEmpty: some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Your requests")
                Text("Nothing pending yet")
                    .font(BrandFont.display(18, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("Submit a viral look and you’ll track its review — submitted, reviewed, shared, live — right here.")
                    .font(BrandFont.body(12.5)).foregroundStyle(BrandColor.textSecondary)
            }
        }
    }

    /// Web's SubmitViralLookForm cell. On iOS the form itself lives in a sheet
    /// (see SubmitViralLookView for why); this is the card that opens it.
    private var submitCard: some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "Spotted a new one?")
                Text("Submit a viral look")
                    .font(BrandFont.display(18, .semibold)).foregroundStyle(BrandColor.textPrimary)
                Text("Paste the link and name it. Our team vets it and shares it with pros before it goes live.")
                    .font(BrandFont.body(12.5)).foregroundStyle(BrandColor.textSecondary)
                Button { showSubmit = true } label: {
                    Text("Submit for review")
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(BrandColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
    }

    /// Submitted · Reviewed · Shared · Live — current node from the look status.
    private func pipeline(status: String?) -> some View {
        let steps = ["Submitted", "Reviewed", "Shared", "Live"]
        let current = status == "IN_REVIEW" ? 2 : 0
        return HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                VStack(spacing: 7) {
                    Circle()
                        .fill(i < current ? BrandColor.accent : (i == current ? BrandColor.gold : BrandColor.textPrimary.opacity(0.16)))
                        .frame(width: 10, height: 10)
                    Text(step.uppercased())
                        .font(BrandFont.mono(8)).tracking(0.4)
                        .foregroundStyle(i <= current ? BrandColor.textSecondary : BrandColor.textMuted)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}