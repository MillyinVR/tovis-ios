// The "Me" tab — a native rebuild of the web client dashboard
// (app/client/(gated)/ClientMeDashboard.tsx + /api/v1/me). Same sections in the
// same order: profile header + stats, creator card, upcoming, Your Looks, and
// the BOARDS / FOLLOWING / HISTORY tabs. Reads GET /api/v1/me via MeService.
import SwiftUI
import TovisKit

struct MeView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded(ClientMe)
        case failed(String)
    }

    private enum MeTab: String, CaseIterable {
        case boards = "BOARDS"
        case following = "FOLLOWING"
        case history = "HISTORY"
    }

    @State private var phase: Phase = .loading
    @State private var tab: MeTab = .boards
    /// The client's shareable invite link. Loaded best-effort: until the
    /// backend ships GET /client/referrals/invite-link this 404s and the
    /// invite card simply stays hidden.
    @State private var inviteLink: ClientInviteLink?
    /// Drives the "New board" create sheet from the BOARDS tab.
    @State private var showingCreateBoard = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch phase {
                    case .loading:
                        loadingState
                    case let .failed(message):
                        errorState(message)
                    case let .loaded(me):
                        content(me)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await load() }
            .task { if case .loading = phase { await load() } }
            .onChange(of: session.refreshTick) { Task { await load() } }
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Loaded content

    @ViewBuilder
    private func content(_ me: ClientMe) -> some View {
        header(me)

        if me.creator.isCreator {
            creatorCard(me.creator).padding(.top, 24)
        }

        if let upcoming = me.upcomingNotificationBooking {
            upcomingCard(upcoming).padding(.top, 24)
        }

        if let invite = inviteLink {
            inviteCard(invite).padding(.top, 24)
        }

        if !me.myLooks.isEmpty {
            yourLooks(me.myLooks).padding(.top, 32)
        }

        sectionTabs.padding(.top, 32)

        Group {
            switch tab {
            case .boards: boardsTab(me.boards, handle: me.profile.handle)
            case .following: followingTab(me.following.items)
            case .history: historyTab(me.history)
            }
        }
        .padding(.top, 18)
    }

    // MARK: - Header

    private func header(_ me: ClientMe) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(formattedHandle(me).uppercased())
                    .font(BrandFont.mono(11))
                    .tracking(1.8)
                    .foregroundStyle(BrandColor.textSecondary)
                Spacer()
                settingsButton(me)
            }

            HStack(alignment: .top, spacing: 16) {
                BrandAvatar(name: displayName(me), avatarUrl: me.profile.avatarUrl, size: 86)

                VStack(alignment: .leading, spacing: 0) {
                    Text(displayName(me))
                        .font(BrandFont.display(28, .semibold).italic())
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)

                    if let since = memberSince(me) {
                        Text("joined \(since)")
                            .font(BrandFont.body(14))
                            .foregroundStyle(BrandColor.textSecondary)
                            .padding(.top, 8)
                    }

                    HStack(alignment: .bottom, spacing: 22) {
                        if me.profile.isPublicProfile {
                            stat("FOLLOWERS", me.counts.followers)
                        }
                        stat("BOARDS", me.counts.boards)
                        stat("SAVED", me.counts.saved)
                        stat("BOOKED", me.counts.booked)
                    }
                    .padding(.top, 18)
                }
            }
            .padding(.top, 20)
        }
    }

    /// The gear that opens the Settings hub (profile · notifications · appearance ·
    /// sign out). Replaced the old inline account Menu — theme + sign out moved into
    /// the hub, matching the pro Profile tab's account section.
    private func settingsButton(_ me: ClientMe) -> some View {
        NavigationLink {
            ClientSettingsHubView(email: me.user.email)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 24))
                .foregroundStyle(BrandColor.textSecondary)
        }
        .buttonStyle(.plain)
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(value)")
                .font(BrandFont.display(18, .bold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(label)
                .font(BrandFont.mono(10))
                .tracking(1.6)
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    // MARK: - Creator card

    private func creatorCard(_ creator: ClientMeCreator) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 14) {
                Label("YOUR INFLUENCE", systemImage: "sparkles")
                    .font(BrandFont.mono(10))
                    .tracking(1.6)
                    .foregroundStyle(BrandColor.textSecondary)
                    .labelStyle(.titleAndIcon)

                Divider().overlay(BrandColor.textMuted.opacity(0.12))

                HStack(spacing: 16) {
                    influenceStat("SAVES ON YOUR LOOKS", creator.savesOnYourLooks)
                    Rectangle().fill(BrandColor.textMuted.opacity(0.12)).frame(width: 1, height: 34)
                    influenceStat("BOOKED FROM YOU", creator.bookedFromYou)
                }
            }
        }
    }

    private func influenceStat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(value)")
                .font(BrandFont.display(18, .bold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(label)
                .font(BrandFont.mono(9))
                .tracking(1.2)
                .foregroundStyle(BrandColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Invite a friend

    /// The web /client/referrals InviteLinkCard, condensed: the TOV-XXXX-XXXX
    /// code + a system share sheet for the absolutized /c/{code} URL.
    private func inviteCard(_ invite: ClientInviteLink) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 12) {
                Label("INVITE A FRIEND", systemImage: "gift")
                    .font(BrandFont.mono(10))
                    .tracking(1.6)
                    .foregroundStyle(BrandColor.textSecondary)
                    .labelStyle(.titleAndIcon)

                Text("Share your personal link. When a friend signs up and books, the referral is credited to you — same as a tap on your physical card.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)

                HStack(spacing: 10) {
                    Text(invite.shortCodeDisplay)
                        .font(BrandFont.mono(13))
                        .tracking(0.8)
                        .foregroundStyle(BrandColor.textPrimary)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(BrandColor.bgPrimary.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(BrandColor.textMuted.opacity(0.18), lineWidth: 1))

                    Spacer()

                    if let url = inviteShareURL(invite) {
                        ShareLink(
                            item: url,
                            subject: Text("Invite a friend"),
                            message: Text("Book with my link:")
                        ) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(BrandFont.body(13, .semibold))
                                .foregroundStyle(BrandColor.onAccent)
                                .padding(.vertical, 9)
                                .padding(.horizontal, 14)
                                .background(BrandColor.accent)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Absolutized share URL for the root-relative invite path. Mirrors the
    /// app's other ShareLink origins (hardcoded canonical web host).
    private func inviteShareURL(_ invite: ClientInviteLink) -> URL? {
        URL(string: "https://www.tovis.app\(invite.path)")
    }

    // MARK: - Upcoming

    private func upcomingCard(_ booking: ClientBooking) -> some View {
        NavigationLink {
            BookingDetailView(booking: booking, onDecision: { await load() })
        } label: {
            BrandSurface(tint: BrandColor.accent.opacity(0.08)) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Circle().fill(BrandColor.accent).frame(width: 6, height: 6)
                        Text("UPCOMING")
                        Text("·")
                        Text(Wire.dateTime(booking.scheduledFor, timeZone: booking.timeZone))
                    }
                    .font(BrandFont.mono(10))
                    .tracking(1.4)
                    .foregroundStyle(BrandColor.accent)
                    .lineLimit(1)

                    Text(booking.display.title)
                        .font(BrandFont.body(16, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)

                    let pieces = [
                        booking.professional?.displayName,
                        Wire.money(booking.checkout.totalAmount ?? booking.checkout.subtotalSnapshot),
                    ].compactMap { $0 }
                    if !pieces.isEmpty {
                        Text(pieces.joined(separator: " · "))
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Your looks

    private func yourLooks(_ looks: [ClientMeLook]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("YOUR LOOKS")
                    .font(BrandFont.mono(11)).tracking(1.4)
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer()
                Text("\(looks.count)")
                    .font(BrandFont.mono(11)).tracking(1.2)
                    .foregroundStyle(BrandColor.textSecondary)
            }
            LazyVGrid(columns: twoCol, spacing: 18) {
                ForEach(looks) { look in
                    MeLookCard(look: look) { id, isPublic in
                        await setLookVisibility(id, isPublic: isPublic)
                    }
                }
            }
        }
    }

    // MARK: - Tabs

    private var sectionTabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 28) {
                ForEach(MeTab.allCases, id: \.self) { item in
                    let active = item == tab
                    Button { tab = item } label: {
                        VStack(spacing: 10) {
                            Text(item.rawValue)
                                .font(BrandFont.mono(12)).tracking(0.8)
                                .foregroundStyle(active ? BrandColor.textPrimary : BrandColor.textSecondary)
                            Rectangle()
                                .fill(active ? BrandColor.accent : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            Rectangle().fill(BrandColor.textMuted.opacity(0.12)).frame(height: 1)
        }
    }

    @ViewBuilder
    private func boardsTab(_ boards: [ClientMeBoard], handle: String?) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Spacer()
                Button { showingCreateBoard = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                        Text("New board").font(BrandFont.body(13, .semibold))
                    }
                    .foregroundStyle(BrandColor.accent)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(BrandColor.accent.opacity(0.10), in: Capsule())
                    .overlay(Capsule().stroke(BrandColor.accent.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New board")
            }

            if boards.isEmpty {
                emptyState("No boards yet", "Create a board or save looks from the feed to start building.")
            } else {
                LazyVGrid(columns: twoCol, spacing: 18) {
                    ForEach(boards) { board in
                        NavigationLink {
                            BoardDetailView(board: board, ownerHandle: handle)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                boardPreview(board.previewImageUrls)
                                Text(board.name)
                                    .font(BrandFont.body(14, .semibold))
                                    .foregroundStyle(BrandColor.textPrimary)
                                    .lineLimit(1)
                                Text("\(board.itemCount) SAVED")
                                    .font(BrandFont.mono(9)).tracking(1.2)
                                    .foregroundStyle(BrandColor.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(isPresented: $showingCreateBoard) {
            CreateBoardView { _ in Task { await load() } }
        }
    }

    @ViewBuilder
    private func followingTab(_ items: [ClientMeFollowingItem]) -> some View {
        if items.isEmpty {
            emptyState("No follows yet", "When you follow a pro, they’ll show up here.")
        } else {
            VStack(spacing: 12) {
                ForEach(items) { item in
                    NavigationLink {
                        ProProfileView(professionalId: item.professional.id,
                                       fallbackName: item.professional.displayName)
                    } label: {
                        BrandSurface {
                            HStack(spacing: 12) {
                                BrandAvatar(name: item.professional.displayName,
                                            avatarUrl: item.professional.avatarUrl, size: 52)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.professional.displayName)
                                        .font(BrandFont.body(15, .semibold))
                                        .foregroundStyle(BrandColor.textPrimary)
                                    if let handle = item.professional.handle {
                                        Text("@\(handle)")
                                            .font(BrandFont.body(12))
                                            .foregroundStyle(BrandColor.textSecondary)
                                    }
                                    if let subtitle = item.professional.subtitle {
                                        Text(subtitle)
                                            .font(BrandFont.body(12))
                                            .foregroundStyle(BrandColor.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(BrandColor.textMuted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func historyTab(_ items: [ClientMeHistoryItem]) -> some View {
        if items.isEmpty {
            emptyState("No history yet", "Your upcoming and past bookings will appear here.")
        } else {
            VStack(spacing: 18) {
                ForEach(items) { item in
                    NavigationLink {
                        BookingDetailView(booking: item.booking, onDecision: { await load() })
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            MediaTile(url: item.heroImageUrl, fallback: item.booking.display.title, aspect: 1.18)
                            Text(item.booking.display.title)
                                .font(BrandFont.body(14, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                                .lineLimit(1)
                            Text(item.label)
                                .font(BrandFont.mono(9)).tracking(1.2)
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Small pieces

    private var twoCol: [GridItem] {
        [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    }

    /// Flip a look's visibility via the backend, returning whether it stuck.
    /// The card updates optimistically and reverts on `false`.
    private func setLookVisibility(_ id: String, isPublic: Bool) async -> Bool {
        do {
            try await session.client.me.setLookVisibility(lookId: id, isPublic: isPublic)
            return true
        } catch {
            return false
        }
    }

    /// 2×2 thumbnail mosaic for a board (mirrors the web PrototypeThumb).
    private func boardPreview(_ urls: [String]) -> some View {
        let four = Array(urls.prefix(4))
        return ZStack {
            BrandColor.bgSecondary
            if four.isEmpty {
                Text("No preview")
                    .font(BrandFont.body(12, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
                    ForEach(0..<4, id: \.self) { i in
                        ZStack {
                            BrandColor.bgPrimary
                            if i < four.count, let u = URL(string: four[i]) {
                                AsyncImage(url: u) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: { Color.clear }
                            }
                        }
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.12), lineWidth: 1)
        )
    }

    private func emptyState(_ title: String, _ body: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(BrandFont.body(15, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(body)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 16)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - States

    private var loadingState: some View {
        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
            .padding(.top, 100)
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
        .padding(.top, 80)
    }

    // MARK: - Derived values (mirror the web page.tsx helpers)

    private func displayName(_ me: ClientMe) -> String {
        if let first = me.profile.firstName?.trimmingCharacters(in: .whitespaces), !first.isEmpty {
            return first
        }
        if let prefix = me.profile.email?.split(separator: "@").first, !prefix.isEmpty {
            return String(prefix)
        }
        return "You"
    }

    private func formattedHandle(_ me: ClientMe) -> String {
        let raw = me.profile.handle?.trimmingCharacters(in: .whitespaces)
            ?? me.profile.email?.split(separator: "@").first.map(String.init)
            ?? "you"
        return raw.hasPrefix("@") ? raw : "@\(raw)"
    }

    /// "Nov '25" — month + 2-digit year in UTC, like the web `formatMemberSince`.
    private func memberSince(_ me: ClientMe) -> String? {
        guard let date = Wire.date(me.user.createdAt) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMM ''yy"
        return f.string(from: date)
    }

    // MARK: - Load

    private func load() async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            let me = try await session.client.me.fetch()
            phase = .loaded(me)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Something went wrong. Please try again.")
        }
        // Best-effort: the invite card hides until the endpoint exists/answers.
        inviteLink = try? await session.client.referrals.inviteLink()
    }
}

// MARK: - Reusable pieces

/// A rounded media tile with a branded fallback when there's no image.
private struct MediaTile: View {
    let url: String?
    let fallback: String
    let aspect: CGFloat

    var body: some View {
        ZStack {
            BrandColor.bgSecondary
            if let url, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ProgressView().tint(BrandColor.accent)
                }
            } else {
                Text(fallback)
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(12)
            }
        }
        .aspectRatio(aspect, contentMode: .fill)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.12), lineWidth: 1)
        )
    }
}

/// One "Your Looks" card with a working Public/Private switch — mirrors the web
/// MyLookCard: optimistic flip, reverts + shows "COULDN'T SAVE" on failure.
private struct MeLookCard: View {
    let look: ClientMeLook
    /// Performs the PATCH; returns whether it stuck.
    let onToggle: (String, Bool) async -> Bool

    @State private var isPublic: Bool
    @State private var busy = false
    @State private var failed = false

    init(look: ClientMeLook, onToggle: @escaping (String, Bool) async -> Bool) {
        self.look = look
        self.onToggle = onToggle
        _isPublic = State(initialValue: look.isPublic)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MediaTile(url: look.imageUrl, fallback: look.name, aspect: 1)

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(look.name)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    Text(failed ? "COULDN’T SAVE" : (isPublic ? "PUBLIC" : "PRIVATE"))
                        .font(BrandFont.mono(9)).tracking(1.2)
                        .foregroundStyle(failed ? BrandColor.ember : BrandColor.textSecondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { isPublic },
                    set: { _ in Task { await toggle() } }
                ))
                .labelsHidden()
                .tint(BrandColor.accent)
                .disabled(busy)
            }
        }
    }

    private func toggle() async {
        guard !busy else { return }
        let next = !isPublic
        busy = true
        failed = false
        isPublic = next // optimistic
        let ok = await onToggle(look.id, next)
        if !ok {
            isPublic = !next // revert
            failed = true
        }
        busy = false
    }
}