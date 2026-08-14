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
                Text(displayName)
                    .font(BrandFont.display(34, .semibold).italic())
                    .foregroundStyle(BrandColor.textPrimary)
            }
            Spacer()
            // The bell only. The envelope beside it was a second door onto the
            // Inbox, which the footer already carries its own tab (and unread
            // badge) for — the web header has never had one either (Tori,
            // 2026-08-14). Notifications keep a bell because the footer has no
            // tab for them.
            notificationsBell
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

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 18 { return "Good afternoon" }
        return "Good evening"
    }

    /// The greeting line. The NAME comes from the server (`ClientHome.displayName`
    /// — the client's own first name, else their email), so the phone and the web
    /// greet the same person the same way.
    ///
    /// 🔴 It used to be derived here from the email's local part, which made
    /// `demo-maya@tovis.app` read "Demo." — and, because `session.currentUser` is
    /// nil until the session loads, every COLD LAUNCH fell through to
    /// "Welcome back." That fallback survives only for the moment before the home
    /// payload lands; nothing is invented from an address any more.
    private var displayName: String {
        if case let .loaded(home) = phase {
            let name = home.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty { return "\(name)." }
        }
        return "Welcome back."
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

        ViralLooksBand(liveLooks: home.viralLive, pending: home.viralPending.first,
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
        UpcomingCard(
            booking: home.upcoming,
            upcomingCount: home.upcomingCount,
            proRating: home.upcomingProRating,
        )
    }

    // Every section keeps its heading and explains itself when it is empty
    // (Tori, 2026-08-14) — so a client on day one sees the shape of the whole
    // home rather than a screen that grows cards as they use it. These two used
    // to be hidden when empty, which is why the phone and the web showed
    // DIFFERENT sets of sections to the same account.
    @ViewBuilder
    private func rightColumn(_ home: ClientHome) -> some View {
        FavoriteProsCard(favoritePros: home.favoritePros)
        FavoritedServicesCard(services: home.favoriteServices)
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

/// The copy + CTA an empty home section shows. Every section keeps its heading
/// and explains itself rather than disappearing (Tori, 2026-08-14), so a client
/// on day one sees the shape of the whole screen. Mirrors the web sections'
/// empty states, which read the same way.
private struct HomeEmptyState: View {
    let title: String
    /// Named `message`, not `body` — `body` is `View`'s own requirement.
    let message: String
    let cta: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(message)
                .font(BrandFont.body(11.5))
                .foregroundStyle(BrandColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            NavigationLink {
                DiscoverView()
            } label: {
                Text(cta)
                    .font(BrandFont.body(11.5, .bold))
                    .foregroundStyle(BrandColor.textSecondary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(BrandColor.textPrimary.opacity(0.16), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


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
        case let .aftercarePaymentDue(booking, aftercare, beforeAfter):
            aftercarePayment(booking, aftercare, beforeAfter)
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

    private func aftercarePayment(
        _ booking: HomeBooking,
        _ aftercare: HomeAftercare,
        _ beforeAfter: HomeBeforeAfter?,
    ) -> some View {
        let title = booking.service?.name ?? "Your visit"
        let due = Wire.money(booking.totalAmount)
        let proName = booking.professional?.displayName ?? "your pro"
        let notes = aftercare.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Which visit this is — the web card has always said. Without it the
        // card names a service and a pro and leaves the client to guess the day.
        let when = Wire.dateTime(booking.scheduledFor, timeZone: booking.resolvedTimeZone)
        let place = booking.location?.name ?? booking.location?.city
        let subLine = [when, place].compactMap { $0 }.joined(separator: " · ")

        // 🔴 Accent is the ACCENT, not ember. "Your summary is ready" is good
        // news, and ember is what this app paints an error in — the web card has
        // always used terra here, so the same state read as an alarm on the phone
        // and as a result on the desktop (Tori, 2026-08-14: teal on both).
        return NavigationLink { AftercareInboxView() } label: {
            HomeCard(accentEdge: BrandColor.accent) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        iconChip("doc.text", tint: BrandColor.accent)
                        Pill(text: "Summary ready", color: BrandColor.accent)
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
                    // The pro's own before/after, the strongest thing in the
                    // card and the reason to open it. Two thumbs rather than the
                    // web's drag-slider: the whole card is one tap into the
                    // summary, where the full comparison lives.
                    if let beforeAfter, beforeAfter.hasAny {
                        HStack(spacing: 8) {
                            beforeAfterThumb(beforeAfter.beforeUrl, label: "BEFORE")
                            beforeAfterThumb(beforeAfter.afterUrl, label: "AFTER")
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(title) with \(proName)")
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        if !subLine.isEmpty {
                            Text(subLine)
                                .font(BrandFont.mono(11))
                                .foregroundStyle(BrandColor.textMuted)
                                .lineLimit(1)
                        }
                    }
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

    /// One half of the before/after pair. A missing phase renders its own empty
    /// tile rather than collapsing the row, so BEFORE and AFTER stay in the same
    /// places whichever one the pro actually shot.
    @ViewBuilder
    private func beforeAfterThumb(_ url: String?, label: String) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(BrandColor.textPrimary.opacity(0.06))
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            }
            Text(label)
                .font(BrandFont.mono(9)).tracking(0.8)
                .foregroundStyle(BrandColor.textPrimary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(BrandColor.bgPrimary.opacity(0.6))
                .clipShape(Capsule())
                .padding(7)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                }

                // The full claim surface — priority offers with live countdowns
                // + any pro-proposed waitlist times (the /client/offers page).
                //
                // OUTSIDE the invites branch on purpose: those are two different
                // feeds, so a client can have a pro-proposed time waiting with
                // zero last-minute invites. Nested in the non-empty branch, this
                // door shut exactly when the only thing behind it was the offer.
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
    @Environment(SessionModel.self) private var session

    let booking: HomeBooking?
    let upcomingCount: Int
    let proRating: HomeRating?

    /// The resolved booking behind "View booking", and the resolved thread behind
    /// the message button. Both are resolved on tap because there is no
    /// single-booking client GET (see `BookingsService.booking(id:)`) — the same
    /// pattern AftercareInboxView and PriorityOffersView already use.
    @State private var bookingNav: ClientBookingNav?
    @State private var threadNav: MessageThreadNav?
    @State private var resolving: Resolve?
    @State private var resolveError: String?

    private enum Resolve { case booking, thread }

    // BOTH states reach AppointmentsView through the "All bookings →" line. The
    // empty state used to be inert text, which was survivable only while the
    // footer carried a Bookings tab; bookings now live in the home area (see
    // ClientTab), and AppointmentsView is the only surface listing PENDING
    // bookings — which is exactly what a client staring at "No approved bookings
    // yet" has. An inert empty card here means they cannot open, or cancel, their
    // own request. Neither branch may lose that line.
    var body: some View {
        Group {
            if let booking { card(booking) } else { empty }
        }
        .navigationDestination(item: $bookingNav) { nav in
            BookingDetailView(booking: nav.booking)
        }
        .navigationDestination(item: $threadNav) { nav in
            ThreadView(thread: nav.thread)
        }
    }

    /// The row both states share: names what else is waiting when there is more
    /// than one upcoming, and otherwise just names the destination.
    private func allBookingsLine(more: Int) -> some View {
        NavigationLink {
            AppointmentsView()
        } label: {
            Text(more > 0 ? "\(more) more upcoming →" : "All bookings →")
                .font(BrandFont.body(12.5, .semibold))
                .foregroundStyle(BrandColor.textMuted)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    /// Where the pro works — studio AND city when both exist, as the web card
    /// reads it ("Halo Studio · Brooklyn"). The name alone does not tell a client
    /// whether this is the salon near them.
    private func placeLine(_ booking: HomeBooking) -> String? {
        let parts = [booking.location?.name, booking.location?.city]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return booking.professional?.location
    }

    /// Resolves the full booking, then pushes its detail. The card cannot build a
    /// `ClientBooking` from the home payload — it carries a different, smaller
    /// shape — so the id is exchanged for the real thing first.
    private func openBooking(_ id: String) async {
        resolving = .booking
        resolveError = nil
        defer { resolving = nil }
        do {
            if let full = try await session.client.bookings.booking(id: id) {
                bookingNav = ClientBookingNav(booking: full)
            } else {
                resolveError = "We couldn’t open that booking. Pull to refresh."
            }
        } catch {
            resolveError = "We couldn’t open that booking. Pull to refresh."
        }
    }

    private func openThread(_ bookingId: String) async {
        resolving = .thread
        resolveError = nil
        defer { resolving = nil }
        do {
            if let thread = try await session.client.messages.openBookingThread(
                bookingId: bookingId,
            ) {
                threadNav = MessageThreadNav(thread: thread)
            } else {
                resolveError = "We couldn’t open that conversation."
            }
        } catch {
            resolveError = "We couldn’t open that conversation."
        }
    }

    private func card(_ booking: HomeBooking) -> some View {
        let pro = booking.professional
        let total = Wire.money(booking.totalAmount)
        let when = Wire.dateTime(booking.scheduledFor, timeZone: booking.resolvedTimeZone)
        let duration = formatDuration(booking.totalDurationMinutes)
        let location = placeLine(booking)
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
                        if location != nil || proRating != nil {
                            HStack(spacing: 5) {
                                if let location {
                                    Text(location).lineLimit(1)
                                }
                                if location != nil, proRating != nil {
                                    Text("·")
                                }
                                if let proRating {
                                    Text("\(proRating.display)★")
                                        .foregroundStyle(BrandColor.textSecondary)
                                        .accessibilityLabel(
                                            "\(proRating.display) out of 5, from \(proRating.count) reviews",
                                        )
                                }
                            }
                            .font(BrandFont.body(12.5))
                            .foregroundStyle(BrandColor.textMuted)
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

                // The two actions the web card has always had. Without them the
                // only route out of this card was the bookings LIST — from their
                // own home a client could not open the appointment itself, and
                // could not message the pro at all.
                HStack(spacing: 10) {
                    Button {
                        Task { await openBooking(booking.id) }
                    } label: {
                        Group {
                            if resolving == .booking {
                                ProgressView().tint(BrandColor.onAccent)
                            } else {
                                Text("View booking")
                                    .font(BrandFont.body(15, .semibold))
                                    .foregroundStyle(BrandColor.onAccent)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(BrandColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .opacity(resolving != nil ? 0.6 : 1)
                    }
                    .disabled(resolving != nil)

                    Button {
                        Task { await openThread(booking.id) }
                    } label: {
                        Group {
                            if resolving == .thread {
                                ProgressView().tint(BrandColor.textSecondary)
                            } else {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(BrandColor.textSecondary)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(BrandColor.textPrimary.opacity(0.16), lineWidth: 1),
                        )
                    }
                    .disabled(resolving != nil)
                    .accessibilityLabel("Message \(pro?.displayName ?? "your pro")")
                }

                if let resolveError {
                    Text(resolveError)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.ember)
                }

                allBookingsLine(more: more)
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
                allBookingsLine(more: 0)
                    .padding(.top, 8)
            }
        }
    }
}

// MARK: - Favorite pros

private struct FavoriteProsCard: View {
    let favoritePros: [HomeFavoritePro]

    private var pros: [HomeProfessional] {
        favoritePros.compactMap { $0.professional }.prefix(12).map { $0 }
    }

    var body: some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(
                    text: favoritePros.isEmpty
                        ? "Favorite pros"
                        : "Favorite pros · \(favoritePros.count)",
                )
                if pros.isEmpty {
                    HomeEmptyState(
                        title: "No favorite pros yet.",
                        message: "Favorite pros from Looks or Discover and they’ll show up here.",
                        cta: "Find pros",
                    )
                } else {
                    // A picture-led card that scrolls left to right (Tori,
                    // 2026-08-14). The rail keeps every card the same size
                    // however many there are, so a third favourite no longer
                    // leaves a half-empty second row of a two-up grid.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 11) {
                            ForEach(Array(pros.enumerated()), id: \.element.id) { index, pro in
                                NavigationLink {
                                    ProProfileView(professionalId: pro.id, fallbackName: pro.displayName)
                                } label: {
                                    FavoriteTile(
                                        imageUrl: pro.avatarUrl,
                                        fallbackText: initials(pro.displayName),
                                        fallbackTint: nil,
                                        index: index,
                                        title: pro.displayName,
                                        subtitle: pro.professionType?.capitalized,
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                    // Let the rail run to the card's edges while the cards keep
                    // their inset — the same trick the web rail uses.
                    .padding(.horizontal, -16)
                    .padding(.leading, 16)
                }
            }
        }
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

/// One card in a favourites rail: the picture, then the info, then Book. Shared
/// by pros and services so the two rails cannot drift into different shapes.
private struct FavoriteTile: View {
    let imageUrl: String?
    /// Drawn over the gradient when there is no picture (a pro's initials).
    let fallbackText: String?
    /// Drawn over the tint when there is no picture (a service's heart).
    let fallbackTint: Color?
    let index: Int
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let fallbackTint {
                    fallbackTint.opacity(0.15)
                } else {
                    gradientAvatar(index)
                }
                if let imageUrl, let parsed = URL(string: imageUrl) {
                    AsyncImage(url: parsed) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                } else if let fallbackTint {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 22)).foregroundStyle(fallbackTint)
                } else if let fallbackText {
                    Text(fallbackText)
                        .font(BrandFont.display(20, .semibold))
                        .foregroundStyle(BrandColor.onAccent)
                }
            }
            .frame(width: 152, height: 112)
            .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(BrandFont.body(13.5, .semibold)).foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
                        .lineLimit(1)
                }
                Text("Book")
                    .font(BrandFont.body(11.5, .bold)).foregroundStyle(BrandColor.onAccent)
                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                    .background(BrandColor.accent).clipShape(Capsule())
                    .padding(.top, 6)
            }
            .padding(12)
        }
        .frame(width: 152, alignment: .leading)
        .background(BrandColor.textPrimary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
            .stroke(BrandColor.textPrimary.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - Favorited services

private struct FavoritedServicesCard: View {
    let services: [HomeFavoriteService]

    var body: some View {
        HomeCard {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(
                    text: services.isEmpty
                        ? "Favorited services"
                        : "Favorited services · \(services.count)",
                )
                if services.isEmpty {
                    HomeEmptyState(
                        title: "No favorited services yet.",
                        message: "Tap the heart on a service and it’ll be one tap from booking here.",
                        cta: "Find services",
                    )
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 11) {
                            let rows = Array(services.prefix(12).enumerated())
                            ForEach(rows, id: \.element.id) { index, fav in
                                if let service = fav.service {
                                    NavigationLink {
                                        DiscoverView()
                                    } label: {
                                        FavoriteTile(
                                            imageUrl: service.defaultImageUrl,
                                            fallbackText: nil,
                                            fallbackTint: tint(index),
                                            index: index,
                                            title: service.name,
                                            subtitle: meta(service),
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                    .padding(.horizontal, -16)
                    .padding(.leading, 16)
                }
            }
        }
    }

    private func tint(_ index: Int) -> Color {
        let tints = [BrandColor.accent, BrandColor.gold, BrandColor.iris]
        return tints[index % tints.count]
    }

    /// A STARTING price, never a bare figure — the pro re-quotes at the chair.
    private func meta(_ service: HomeFavoriteServiceRef) -> String? {
        let parts = [service.category?.name,
                     Wire.money(service.minPrice).map { "from \($0)" },
                     formatDuration(service.defaultDurationMinutes)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
                    HomeEmptyState(
                        title: "You’re not on any waitlists.",
                        message: "Join one and we’ll hold your place here.",
                        cta: "Find services",
                    )
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
            // The client's REAL place in this pro's queue, from the server. It
            // used to be `index + 1` — this row's position in the viewer's own
            // list — so a client on a single waitlist always read "#1 IN LINE"
            // however many people were ahead of them, while the pro looking at
            // the same entry could be seeing #7. nil means the server could not
            // establish it, and no badge is honest where a number would not be.
            if let position = entry.queuePosition {
                Text("#\(position) IN LINE")
                    .font(BrandFont.mono(10)).tracking(0.6).foregroundStyle(BrandColor.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(BrandColor.accent.opacity(0.10)).clipShape(Capsule())
            }
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
    /// Every approved look, not just the first: with more than one they list as
    /// strips (see `liveStrips`), which a single hero could never do.
    let liveLooks: [HomeViral]
    let pending: HomeViral?
    let pendingMore: Int

    /// Board-style rows, used only once there is more than one live look.
    private static let maxLiveStrips = 4

    private var live: HomeViral? { liveLooks.first }
    private var liveStrips: [HomeViral] {
        liveLooks.count > 1 ? Array(liveLooks.prefix(Self.maxLiveStrips)) : []
    }
    private var liveOverflow: Int { max(0, liveLooks.count - liveStrips.count) }
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
            // One live look keeps the hero — it has room to sell the look. TWO
            // OR MORE list like the client's boards (Tori, 2026-08-14): a hero
            // can only show the first, and "+N more in the feed" sends them
            // somewhere else to find looks already approved for them.
            if !liveStrips.isEmpty {
                VStack(spacing: 12) {
                    ForEach(Array(liveStrips.enumerated()), id: \.element.id) { index, look in
                        liveStrip(look, index: index)
                    }
                    if liveOverflow > 0 {
                        Text("+\(liveOverflow) more live in the feed →")
                            .font(BrandFont.body(12, .semibold))
                            .foregroundStyle(BrandColor.textSecondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else if let live {
                liveHero(live)
            } else {
                liveEmpty
            }
            if let pending { pendingHero(pending) } else { pendingEmpty }
            submitCard
        }
        .sheet(isPresented: $showSubmit) {
            SubmitViralLookView(onSubmitted: onSubmitted)
        }
    }

    /// One approved look as the wide strip the client already knows from their
    /// boards (`BoardStripCard` on web): the 2.05:1 card, a left-weighted scrim,
    /// the name over a meta line. The picture is the reviewer's cover when there
    /// is one (set in /admin/viral-requests) and a gradient when there is not —
    /// a look can be published before anyone has a shot of it.
    private func liveStrip(_ look: HomeViral, index: Int) -> some View {
        ZStack(alignment: .bottomLeading) {
            gradientAvatar(index)
            if let cover = look.coverImage, let parsed = URL(string: cover) {
                AsyncImage(url: parsed) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            }
            LinearGradient(
                colors: [BrandColor.bgPrimary.opacity(0.85),
                         BrandColor.bgPrimary.opacity(0.25),
                         .clear],
                startPoint: .leading, endPoint: .trailing,
            )
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    HStack(spacing: 6) {
                        Circle().fill(BrandColor.ember).frame(width: 6, height: 6)
                        Text("LIVE NOW").font(BrandFont.mono(9.5)).tracking(1.4)
                            .foregroundStyle(BrandColor.textPrimary)
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
                Text(look.name)
                    .font(BrandFont.body(17, .bold)).foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1)
                Text(look.fanOutCount > 0
                        ? "\(look.fanOutCount) \(look.fanOutCount == 1 ? "pro" : "pros") now offer this"
                        : "Newly approved")
                    .font(BrandFont.mono(10)).tracking(1.0)
                    .foregroundStyle(BrandColor.textSecondary)
                    .padding(.top, 6)
            }
            .padding(14)
        }
        .aspectRatio(2.05, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(BrandColor.textPrimary.opacity(0.10), lineWidth: 1))
    }

    private func liveHero(_ look: HomeViral) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [BrandColor.accent.opacity(0.55), BrandColor.bgPrimary],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let cover = look.coverImage, let parsed = URL(string: cover) {
                AsyncImage(url: parsed) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            }
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