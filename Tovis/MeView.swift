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

    /// DEBUG: start on a named panel, so BOARDS / FOLLOWING / HISTORY can each be
    /// photographed before shipping. Same mechanism and same reasoning as
    /// `TOVIS_DEBUG_OPEN_TAB` and `TOVIS_DEBUG_PROFILE_TAB` — this machine cannot
    /// drive the simulator with synthetic taps, so a panel reachable ONLY by
    /// tapping would otherwise never be looked at. Release always starts on
    /// BOARDS.
    ///
    ///     SIMCTL_CHILD_TOVIS_DEBUG_ME_TAB=history xcrun simctl launch …
    private static var initialTab: MeTab {
        #if DEBUG
        let raw = ProcessInfo.processInfo.environment["TOVIS_DEBUG_ME_TAB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if let raw, let wanted = MeTab(rawValue: raw) { return wanted }
        #endif
        return .boards
    }

    @State private var phase: Phase = .loading
    @State private var tab: MeTab = Self.initialTab
    /// The client's shareable invite link. Loaded best-effort: until the
    /// backend ships GET /client/referrals/invite-link this 404s and the
    /// invite card simply stays hidden.
    @State private var inviteLink: ClientInviteLink?
    /// Drives the "New board" create sheet from the BOARDS tab.
    @State private var showingCreateBoard = false
    /// Drives the Activity feed sheet from the header bell.
    @State private var showActivity = false
    /// Board id → the visibility its switch has flipped to, ahead of the next
    /// `/api/v1/me`. Cleared on every load, so the server always wins in the end.
    @State private var boardVisibilityOverrides: [String: Bool] = [:]
    /// The completed visit whose "Share your look" CTA was tapped on a HISTORY
    /// card. Presented as a sheet from the scroll view — see the note on the
    /// Activity sheet below for why it must not hang off one tab's branch.
    @State private var shareLookFor: ClientBooking?

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
            // 🔴 This MUST hang off the scroll view, not off `boardsTab`. The bell
            // that sets `showActivity` lives in the header, which is on screen for
            // every panel — but the sheet used to be attached inside the BOARDS
            // branch of the tab switch, so on FOLLOWING or HISTORY the modifier was
            // not in the hierarchy at all and the bell silently did nothing while
            // its unread badge kept insisting there was something to read.
            //
            // ClientActivityView brings its own NavigationStack + Done button, so it
            // is presented bare (same as HomeView's notifications sheet). Marking
            // read there signalRefreshes, which reloads this screen and drops the
            // badge.
            .sheet(isPresented: $showActivity) { ClientActivityView() }
            // Same rule as the Activity sheet above: attached to the SCROLL VIEW,
            // not inside the HISTORY branch of the tab switch. A sheet modifier
            // that only exists on one panel is a control that silently does
            // nothing everywhere else.
            .sheet(item: $shareLookFor) { booking in
                ShareLookView(booking: booking) { await load() }
            }
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
            upcomingCard(upcoming, heroUrl: me.upcomingNotificationHeroImageUrl)
                .padding(.top, 24)
        }

        // Tabs sit DIRECTLY under the Upcoming card (Tori, 2026-08-17). A grid
        // of "Your looks" used to sit in this gap and pushed BOARDS / FOLLOWING
        // / HISTORY far below the fold. Each look's visibility switch now rides
        // the history card for the visit it came out of.
        //
        // The invite card moved BELOW the tab content for the same reason: it
        // is a promo, the tabs are this screen's primary navigation, and on a
        // phone the card alone was still enough to push all three off-screen.
        // Web has no such card in this position, so this is also what makes the
        // two platforms read the same.
        sectionTabs.padding(.top, 24)

        Group {
            switch tab {
            case .boards: boardsTab(me.boards, handle: me.profile.handle)
            case .following: followingTab(me.following.items)
            case .history: historyTab(me.history, creator: me.creator)
            }
        }
        .padding(.top, 18)

        if let invite = inviteLink {
            ClientInviteCard(invite: invite).padding(.top, 32)
            referralsLink.padding(.top, 10)
        }
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
                HStack(spacing: 14) {
                    activityBell(me)
                    settingsButton(me)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                BrandAvatar(name: displayName(me), avatarUrl: me.profile.avatarUrl, size: 86)

                VStack(alignment: .leading, spacing: 0) {
                    Text(displayName(me))
                        .font(BrandFont.display(28, .semibold).italic())
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)

                    // The owner's own tier + "top 2% saver · Brooklyn". Until
                    // screen 7 this page showed its owner LESS about themselves
                    // than a stranger visiting /u/{handle} could see.
                    standingRow(me.standing)
                        .padding(.top, 8)

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

    /// The Activity bell + unread badge, mirroring web's Me header (`ClientMeDashboard`
    /// renders the same bell beside the workspace switcher, linking to /client/activity).
    ///
    /// The count rides `GET /api/v1/me` (`activityUnreadCount`) — already fetched for
    /// this screen, so the badge costs no extra request. Web caps the badge at "9+";
    /// so do we.
    private func activityBell(_ me: ClientMe) -> some View {
        Button { showActivity = true } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                    .font(.system(size: 21))
                    .foregroundStyle(BrandColor.textSecondary)
                    // Reserve the badge's corner so the glyph doesn't shift when a
                    // badge appears, and keep a comfortable tap target.
                    .frame(width: 30, height: 30)

                if me.activityUnreadCount > 0 {
                    Text(me.activityUnreadCount > 9 ? "9+" : "\(me.activityUnreadCount)")
                        .font(BrandFont.mono(9))
                        .foregroundStyle(BrandColor.onAccent)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(BrandColor.accent, in: Capsule())
                        .offset(x: 4, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            me.activityUnreadCount > 0
                ? "Activity, \(me.activityUnreadCount) unread"
                : "Activity"
        )
    }

    /// The gear that opens the Settings hub (profile · notifications · appearance ·
    /// sign out). Replaced the old inline account Menu — theme + sign out moved into
    /// the hub, matching the pro Profile tab's account section.
    private func settingsButton(_ me: ClientMe) -> some View {
        NavigationLink {
            ClientSettingsHubView(
                email: me.user.email,
                canSwitchToPro: me.user.canSwitchToPro
            )
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
                // Four tracked mono labels do not fit a phone's width, and the
                // default break put "FOLLOWERS" across two lines as "FOLLOWER /
                // S". A stat label is one word; let it shrink instead.
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Standing

    /// "✦ TASTEMAKER · top 2% saver · Brooklyn".
    ///
    /// The owner's own standing, which until screen 7 only a VISITOR to their
    /// public profile could see. Renders nothing below Rising — an unranked
    /// creator has no standing to state.
    @ViewBuilder
    private func standingRow(_ standing: ClientMeStanding?) -> some View {
        if let standing, standing.isRanked {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Text("✦")
                    Text(standing.tierLabel.uppercased())
                }
                .font(BrandFont.mono(10))
                .tracking(1.0)
                .foregroundStyle(BrandColor.amber)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .overlay(
                    Capsule().stroke(BrandColor.amber, lineWidth: 1)
                )

                if let detail = standing.detail {
                    Text(detail)
                        .font(BrandFont.body(12.5))
                        .foregroundStyle(BrandColor.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }

    // MARK: - Creator card

    private func creatorCard(_ creator: ClientMeCreator) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    Label("YOUR INFLUENCE", systemImage: "sparkles")
                        .font(BrandFont.mono(10))
                        .tracking(1.6)
                        .foregroundStyle(BrandColor.textSecondary)
                        .labelStyle(.titleAndIcon)

                    Spacer()

                    // Level 0 shows no pill: nobody has saved or booked a look
                    // of yours yet, and "Lvl 0" is a grade rather than a start.
                    if let level = creator.level, level.level > 0 {
                        Text("LVL \(level.level)")
                            .font(BrandFont.mono(10))
                            .tracking(1.0)
                            .foregroundStyle(BrandColor.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(BrandColor.accent.opacity(0.10))
                            )
                            .overlay(
                                Capsule().stroke(BrandColor.accent.opacity(0.35), lineWidth: 1)
                            )
                    }
                }

                if let level = creator.level {
                    VStack(alignment: .leading, spacing: 8) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(BrandColor.textMuted.opacity(0.12))
                                Capsule()
                                    .fill(BrandColor.accent)
                                    .frame(
                                        width: max(
                                            0,
                                            min(1, level.progress) * geo.size.width
                                        )
                                    )
                            }
                        }
                        .frame(height: 6)

                        Text(level.progressLabel ?? "Top level reached")
                            .font(BrandFont.body(11.5))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(level.progressLabel ?? "Top level reached")
                }

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
    // The invite card is the shared `ClientInviteCard` (also on the client Home),
    // rendered above from `inviteLink`.

    /// Entry to the "Your Referrals" list. The invite card above is the share
    /// half of the web /client/referrals page; this pushes the list half — the
    /// friends you've referred + any pending "did you refer them?" confirmations.
    private var referralsLink: some View {
        NavigationLink {
            ClientReferralsView()
        } label: {
            HStack(spacing: 10) {
                Text("See your referrals")
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BrandColor.textMuted)
            }
            .padding(.vertical, 13).padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Upcoming

    /// `heroUrl` is the visit's photo — its after-shot, or the look it was booked
    /// from. iOS rendered no thumbnail here at all while web rendered an empty
    /// box; the design puts the appointment's picture in this slot.
    private func upcomingCard(_ booking: ClientBooking, heroUrl: String?) -> some View {
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

                    HStack(alignment: .center, spacing: 13) {
                        MediaTile(url: heroUrl, fallback: "", aspect: 1)
                            .frame(width: 58, height: 58)

                        Text(booking.display.title)
                            .font(BrandFont.body(16, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)

                        Spacer(minLength: 0)
                    }

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
                // The same wide strips a visitor sees on the public profile, so a
                // board looks like the same object to its owner and to everyone
                // else. Wide strips stack one per row on a phone; a wider
                // container (iPad) fits two.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 11) {
                    ForEach(boards) { board in
                        ownedBoardStrip(board, handle: handle)
                    }
                }
            }
        }
        .sheet(isPresented: $showingCreateBoard) {
            CreateBoardView { _ in Task { await load() } }
        }
    }

    /// One of the client's OWN boards: the shared strip, plus the two things only
    /// an owner gets — whether it is shared, and the switch to change that.
    ///
    /// The switch is a SIBLING of the navigation link, never inside its label: a
    /// control inside a link's label is not its own tap target, so tapping it
    /// would open the board instead of flipping it.
    private func ownedBoardStrip(_ board: ClientMeBoard, handle: String?) -> some View {
        ZStack(alignment: .topTrailing) {
            NavigationLink {
                BoardDetailView(board: board, ownerHandle: handle)
            } label: {
                // No `sharedBadge`: the visibility switch overlaid below already
                // states it, and rendering both printed the same fact about the
                // same board twice, eight points apart. Web suppresses it on the
                // same grounds — the badge is for surfaces with no control.
                BoardStripCard(
                    name: board.name,
                    itemCount: board.itemCount,
                    tileImageUrls: board.previewImageUrls,
                    sharedBadge: false
                )
            }
            .buttonStyle(.plain)

            BoardVisibilitySwitch(
                boardId: board.id,
                isShared: Binding(
                    get: { boardIsShared(board) },
                    set: { boardVisibilityOverrides[board.id] = $0 }
                )
            )
            .padding(12)
        }
    }

    /// What this board's visibility is RIGHT NOW: the switch's optimistic answer
    /// when it has one, otherwise what `/api/v1/me` said. Held here rather than
    /// inside the switch so the strip's SHARED badge follows the flip too.
    private func boardIsShared(_ board: ClientMeBoard) -> Bool {
        boardVisibilityOverrides[board.id] ?? board.isShared
    }

    @ViewBuilder
    private func followingTab(_ items: [ClientMeFollowingItem]) -> some View {
        // spacing 0: the rail owns its own bottom gap, so when it has nothing to
        // suggest it leaves no dead space above the list.
        VStack(alignment: .leading, spacing: 0) {
            // Above the list, exactly where web puts it (ClientMeDashboard:798) —
            // and outside the isEmpty branch, so someone with no follows yet gets
            // the suggestions that fix that.
            FollowSuggestionsRail()

            followingList(items)
        }
    }

    @ViewBuilder
    private func followingList(_ items: [ClientMeFollowingItem]) -> some View {
        if items.isEmpty {
            emptyState("No follows yet", "When you follow a pro, they’ll show up here.")
        } else {
            VStack(spacing: 12) {
                ForEach(items) { item in
                    // The pill is a SIBLING of the link, never inside its label:
                    // a control inside a link's label is not its own tap target,
                    // so tapping it would open the pro instead of unfollowing.
                    ZStack(alignment: .trailing) {
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
                                    // Room for the pill that sits over this edge.
                                    Color.clear.frame(width: 92, height: 1)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        MeFollowingPill(professionalId: item.professional.id,
                                        name: item.professional.displayName)
                            .padding(.trailing, 14)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func historyTab(
        _ items: [ClientMeHistoryItem],
        creator: ClientMeCreator
    ) -> some View {
        // Above the list, exactly where web puts it (ClientMeDashboard:827) —
        // and outside the isEmpty branch, because a creator whose looks other
        // people have booked has something to show here even before they have
        // any bookings of their own.
        VStack(alignment: .leading, spacing: 18) {
            if !creator.remixes.isEmpty {
                remixesCard(creator.remixes)
            }

            historyList(items)
        }
    }

    /// "Your looks, remixed" — appointments other people booked from this
    /// client's looks. The native twin of web's `RemixesCard`.
    private func remixesCard(_ remixes: [ClientMeRemix]) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 6) {
                Label("YOUR LOOKS, REMIXED", systemImage: "arrow.triangle.2.circlepath")
                    .font(BrandFont.mono(10)).tracking(1.6)
                    .foregroundStyle(BrandColor.textSecondary)
                    .labelStyle(.titleAndIcon)

                Text("Bookings others made, inspired by a look in your history.")
                    .font(BrandFont.body(12.5))
                    .foregroundStyle(BrandColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    ForEach(Array(remixes.enumerated()), id: \.element.id) { index, remix in
                        remixRow(remix)
                        if index != remixes.count - 1 {
                            Divider().overlay(BrandColor.textMuted.opacity(0.12))
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func remixRow(_ remix: ClientMeRemix) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // "<who> booked your <look>" — the look in accent, as on web.
                (
                    Text(remix.who).font(BrandFont.body(13.5, .bold))
                        + Text(" booked your ").font(BrandFont.body(13.5))
                        + Text(remix.lookName).font(BrandFont.body(13.5, .semibold))
                            .foregroundColor(BrandColor.accent)
                )
                .foregroundStyle(BrandColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

                Text("with \(remix.proName) · \(RelativeDayAgo.label(remix.bookedAt))")
                    .font(BrandFont.body(11.5))
                    .foregroundStyle(BrandColor.textSecondary)
            }

            Spacer(minLength: 8)

            Text("+1 ✦")
                .font(BrandFont.mono(10)).tracking(0.8)
                .foregroundStyle(BrandColor.accent)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func historyList(_ items: [ClientMeHistoryItem]) -> some View {
        if items.isEmpty {
            emptyState("No history yet", "Your upcoming and past bookings will appear here.")
        } else {
            VStack(spacing: 18) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        NavigationLink {
                            BookingDetailView(booking: item.booking, onDecision: { await load() })
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                // The switch sits ON the photo, like web's, so
                                // folding it in costs the list no extra rhythm.
                                MediaTile(url: item.heroImageUrl, fallback: item.booking.display.title, aspect: 1.18)
                                    .overlay(alignment: .topTrailing) {
                                        if let look = item.look {
                                            MeLookVisibilityToggle(look: look) { id, isPublic in
                                                await setLookVisibility(id, isPublic: isPublic)
                                            }
                                            .padding(10)
                                        }
                                    }
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

                        // A completed visit nobody has posted a look from keeps
                        // the "Share your look" CTA — the sibling branch of the
                        // switch above.
                        //
                        // Web has had this on the card since screen 7; native
                        // could only reach ShareLookView by opening the booking
                        // first. Same sheet, same publish callback — this is the
                        // missing entry point, not a second implementation.
                        if item.kind == "completed", item.look == nil {
                            Button {
                                shareLookFor = item.booking
                            } label: {
                                HStack(spacing: 6) {
                                    Text("✦")
                                    Text("Share your look")
                                }
                                .font(BrandFont.body(12, .semibold))
                                .foregroundStyle(BrandColor.accent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule().fill(BrandColor.accent.opacity(0.08))
                                )
                                .overlay(
                                    Capsule().stroke(BrandColor.accent.opacity(0.30), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Small pieces

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
            // The server has just told us what every board's visibility is, so
            // the switches' optimistic answers are spent.
            boardVisibilityOverrides = [:]
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

/// Unfollow (or re-follow) straight from the list of who you follow.
///
/// There was no way to unfollow from the ONE screen that lists your follows —
/// you had to open the pro's profile to find the control. Web has the same pill
/// now. State lives in the shared `FollowToggle` and the request goes through
/// `LooksService.toggleFollow(professionalId:)`, so this is chrome over the
/// existing follow implementation rather than a third one.
///
/// Seeded `following: true` because every row on THIS list is, by definition, a
/// pro the viewer follows — no per-row GET needed to find that out.
private struct MeFollowingPill: View {
    let professionalId: String
    let name: String

    @Environment(SessionModel.self) private var session
    @State private var follow = FollowToggle(following: true, followerCount: 0)

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            Text(follow.following ? "Following" : "Follow")
                .font(BrandFont.body(11.5, .bold))
                .foregroundStyle(follow.following ? BrandColor.textSecondary : BrandColor.onAccent)
                .padding(.vertical, 7).padding(.horizontal, 13)
                .background(
                    follow.following ? AnyShapeStyle(Color.clear) : AnyShapeStyle(BrandColor.accent),
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(
                        BrandColor.textPrimary.opacity(follow.following ? 0.15 : 0), lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(follow.isWorking)
        .opacity(follow.isWorking ? 0.7 : 1)
        .accessibilityLabel(follow.following ? "Unfollow \(name)" : "Follow \(name)")
    }

    private func toggle() async {
        guard follow.begin() != nil else { return }
        do {
            follow.finish(try await session.client.looks.toggleFollow(professionalId: professionalId))
        } catch {
            follow.fail()
        }
    }
}

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
            } else if fallback.isEmpty {
                // No caption to stand in for the photo — say "no picture" with a
                // glyph rather than with words the card prints anyway. Matches
                // web's BookingHeroImage.
                Image(systemName: "camera")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(BrandColor.textSecondary.opacity(0.5))
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

/// The compact Public/Private switch that rides a history card's photo.
///
/// Screen 7 folded this onto the card for the visit the look came out of and
/// dropped the separate "Your looks" grid — one picture-led list instead of two
/// lists holding two halves of the same thing. Behaviour is the web switch's:
/// optimistic flip, reverted on refusal.
///
/// A plain `Button`, not a `Toggle`: this sits inside a `NavigationLink`'s
/// label, where a Toggle's own hit area fights the row's tap.
private struct MeLookVisibilityToggle: View {
    let look: ClientMeHistoryLook
    /// Performs the PATCH; returns whether it stuck.
    let onToggle: (String, Bool) async -> Bool

    @State private var isPublic: Bool
    @State private var busy = false
    @State private var failed = false

    init(look: ClientMeHistoryLook, onToggle: @escaping (String, Bool) async -> Bool) {
        self.look = look
        self.onToggle = onToggle
        _isPublic = State(initialValue: look.isPublic)
    }

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(isPublic ? BrandColor.accent : BrandColor.textSecondary)
                    .frame(width: 5, height: 5)
                Text(failed ? "COULDN’T SAVE" : (isPublic ? "PUBLIC" : "PRIVATE"))
                    .font(BrandFont.mono(9))
                    .tracking(0.9)
            }
            .foregroundStyle(
                failed
                    ? BrandColor.ember
                    : (isPublic ? BrandColor.accent : BrandColor.textSecondary)
            )
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(BrandColor.bgPrimary.opacity(0.75), in: Capsule())
            .overlay(
                Capsule().stroke(
                    (isPublic ? BrandColor.accent : BrandColor.textMuted).opacity(0.35),
                    lineWidth: 1
                )
            )
            .opacity(busy ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel("Look visibility — \(look.name)")
        .accessibilityValue(isPublic ? "Public" : "Private")
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