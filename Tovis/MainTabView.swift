// The signed-in shell: the custom Tovis footer over the client surfaces.
//
// Matches the web client footer 1:1 — Home · Discover · Looks(center feather) ·
// Inbox · Me (see ClientTab + TovisTabBar).
//
// Bookings is NOT a footer tab on either platform: it lives in the home area.
// AppointmentsView is therefore reached by a push from HomeView's Upcoming card,
// which links from BOTH its populated and its empty state — the empty state
// being the one a client whose sole booking is still PENDING actually sees, and
// the reason this must never become conditional. See ClientTab.
//
// Social-first landing: clients open on the Looks feed (the center feather),
// matching the web, where login/verify default a client to `/looks`. Tovis is a
// social platform first, so the feed is always the first thing a client sees.
//
// We keep a real SwiftUI TabView for per-tab state + lazy loading, hide its
// system bar, and overlay our branded bar via safeAreaInset so the raised
// feather can lift above the bar like the web's .tovis-center-lift.
import SwiftUI
import TovisKit

struct MainTabView: View {
    @Environment(SessionModel.self) private var session
    @State private var tab: ClientTab.ID = Self.launchTab
    @State private var messagesBadge: String?
    /// A booking surfaced by a tapped push (`tovis://`-style `href` deep link),
    /// presented over the shell. nil when nothing is being deep-linked.
    @State private var deepLinkBooking: ClientBooking?
    /// The `step` carried on that booking deep link (`?step=consult|aftercare|…`),
    /// so the detail can scroll to the right section. nil = open at the top.
    @State private var deepLinkBookingStep: String?
    /// A conversation surfaced by a tapped message push (`/messages/thread/{id}`),
    /// presented over the shell. nil when nothing is being deep-linked.
    @State private var deepLinkThread: MessageThread?
    /// A single look surfaced by a tapped share link (`/looks/{id}` Universal
    /// Link) or a look push, presented over the shell. Carries only the id — the
    /// detail screen self-fetches, so nothing has to be resolved before routing.
    @State private var deepLinkLook: LookPresentation?
    @State private var deepLinkPublicClient: PublicClientPresentation?
    @State private var deepLinkPublicPro: PublicProPresentation?
    /// The activity feed surfaced by a `/client/activity` push, presented over the
    /// shell. Mirrors HomeView's own notifications sheet.
    @State private var showActivity = false
    /// The chart-consent surface, surfaced by a `/client/settings/chart-sharing`
    /// push (a pro asking to read this client's chart).
    @State private var showChartAccess = false
    /// (The Me tab's header bell presents the same screen from its own state.)
    /// The priority-offers screen surfaced by a `/client/offers` push, presented
    /// over the shell. Carries the `?accept=` recipient id to float + highlight.
    @State private var offersPresentation: OffersPresentation?

    /// Set while a pushed screen asks for the footer to be hidden (a screen whose
    /// own bottom bar the footer would sit on top of) — see `ShellFooterVisibility`.
    @State private var footerHidden = false

    /// Identifiable wrapper so `.sheet(item:)` can carry the optional highlight id.
    private struct OffersPresentation: Identifiable {
        let id = UUID()
        let highlight: String?
    }

    #if DEBUG
    /// DEBUG ONLY — open a screen that has no footer tab and no push-triggered
    /// entry point reachable without a real tap, via
    /// `SIMCTL_CHILD_TOVIS_DEBUG_OPEN_SCREEN=<name>`. Same reasoning as
    /// `TOVIS_DEBUG_OPEN_TAB`: this machine cannot drive the simulator with
    /// synthetic taps, so `AppointmentsView` (pushed from Home's Upcoming card)
    /// and `ClientSettingsHubView` + its sub-screens (pushed from the Me tab's
    /// gear) were otherwise unreachable for a layout pass.
    ///
    /// `look-detail:<lookId>` is the odd one out: `LookDetailView` DOES have an
    /// existing reach path (`TOVIS_DEBUG_OPEN_DEEP_LINK=/looks/{id}`), but that
    /// path opens it as this shell's OWN `.sheet(item: $deepLinkLook)` — which on
    /// iPad gets the system's centered-card treatment for free, the same as
    /// `BookingFlowView`. Most real entry points (a portfolio tile, a board tile,
    /// a tag chip result) instead PUSH it onto a `NavigationStack` that is
    /// already on screen — e.g. Looks' own creator `navigationDestination` into
    /// `ProProfileView`, then a portfolio tile push from there — which gets no
    /// such cap. `.fullScreenCover` (not `.sheet`) is used for all four cases
    /// below deliberately: unlike `.sheet`, it is never auto-centered on iPad,
    /// so it reproduces the SAME uncapped context those push call sites hit,
    /// rather than accidentally exercising the already-fine sheet path again.
    ///
    ///     SIMCTL_CHILD_TOVIS_DEBUG_OPEN_SCREEN=settings xcrun simctl launch …
    ///     SIMCTL_CHILD_TOVIS_DEBUG_OPEN_SCREEN=look-detail:abc123 xcrun simctl launch …
    private static var debugScreenValue: String? {
        let raw = ProcessInfo.processInfo.environment["TOVIS_DEBUG_OPEN_SCREEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }
    @State private var debugShowBookings = MainTabView.debugScreenValue == "bookings"
    @State private var debugShowSettings = MainTabView.debugScreenValue == "settings"
    @State private var debugShowSettingsProfile = MainTabView.debugScreenValue == "settings-profile"
    @State private var debugPushedLookId: String? = {
        guard let value = MainTabView.debugScreenValue, value.hasPrefix("look-detail:") else { return nil }
        return String(value.dropFirst("look-detail:".count))
    }()
    #endif

    /// The tab a launch starts on — Looks, unless a DEBUG build was launched
    /// with `TOVIS_DEBUG_OPEN_TAB` naming another one. Same mechanism and same
    /// reasoning as `ProMainTabView.launchTab`: this machine can't drive the
    /// simulator with synthetic taps, so Home/Discover/Inbox/Me were otherwise
    /// unreachable in an automated pass. Accepts a `ClientTab.ID` raw value
    /// (`home` · `discover` · `looks` · `inbox` · `me`); anything else lands on
    /// Looks as usual.
    ///
    ///     SIMCTL_CHILD_TOVIS_DEBUG_OPEN_TAB=discover xcrun simctl launch …
    private static var launchTab: ClientTab.ID {
        #if DEBUG
        let raw = ProcessInfo.processInfo.environment["TOVIS_DEBUG_OPEN_TAB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let raw, let wanted = ClientTab.ID(rawValue: raw) { return wanted }
        #endif
        return .looks
    }

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tag(ClientTab.ID.home)

            DiscoverView()
                .tag(ClientTab.ID.discover)

            LooksView()
                .tag(ClientTab.ID.looks)

            InboxView()
                .tag(ClientTab.ID.inbox)

            MeView()
                .tag(ClientTab.ID.me)
        }
        .toolbar(.hidden, for: .tabBar)         // hide the system tab bar
        // A pushed screen with its own bottom bar (e.g. a thread's composer) would
        // otherwise be covered by the footer — see `ShellFooterVisibility`. Read
        // the request before installing the bar so the inset collapses to zero
        // while such a screen is up.
        .onPreferenceChange(HidesShellFooterKey.self) { hidden in
            footerHidden = hidden
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !footerHidden {
                TovisTabBar(selected: $tab, messagesBadge: messagesBadge)
            }
        }
        .tint(BrandColor.accent)
        // Keep the Inbox tab badge live (foreground/Realtime + gentle poll).
        .task { await refreshBadge() }
        .onChange(of: session.refreshTick) { Task { await refreshBadge() } }
        .task { await pollBadge() }
        // Push deep-link routing. `.task` catches a link set before this mounted
        // (cold-launch tap); `.onChange` catches taps while the app is running.
        .task { await routeDeepLink(session.pushDeepLink) }
        .onChange(of: session.pushDeepLink) { _, link in
            Task { await routeDeepLink(link) }
        }
        .sheet(item: $deepLinkBooking) { booking in
            NavigationStack {
                BookingDetailView(booking: booking, onDecision: { session.signalRefresh() }, focusStep: deepLinkBookingStep)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { deepLinkBooking = nil }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        .sheet(item: $deepLinkThread) { thread in
            NavigationStack {
                ThreadView(thread: thread)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { deepLinkThread = nil }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        .sheet(item: $deepLinkLook) { look in
            NavigationStack {
                LookDetailView(lookId: look.id, autoStartBooking: look.book)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { deepLinkLook = nil }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        // PublicClientViewerView brings its own back-button top bar and hides the
        // navigation bar, so it is presented bare — a toolbar "Done" here would
        // render a second, competing dismiss control in the same corner.
        .sheet(item: $deepLinkPublicClient) { profile in
            NavigationStack { PublicClientViewerView(handle: profile.handle) }
                .tint(BrandColor.accent)
        }
        // Same treatment as the creator profile above: ProProfileView brings its
        // own back-button band and hides the navigation bar, so it is presented
        // bare rather than under a competing "Done".
        .sheet(item: $deepLinkPublicPro) { pro in
            NavigationStack { ProProfileView(professionalId: pro.professionalId) }
                .tint(BrandColor.accent)
        }
        // ClientActivityView brings its own NavigationStack + Done button (same as
        // HomeView's notifications sheet) — present it bare. This used to open
        // NotificationsView as a placeholder, so a /client/activity push landed on
        // the transactional notification centre instead of the engagement feed it
        // named.
        .sheet(isPresented: $showActivity) { ClientActivityView() }
        // ClientChartAccessView is normally PUSHED from the Settings hub, so it
        // owns no stack of its own — wrap it plus a Done button, like the
        // booking and offers sheets.
        .sheet(isPresented: $showChartAccess) {
            NavigationStack {
                ClientChartAccessView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showChartAccess = false }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        // PriorityOffersView owns no stack (it's also pushed from Home), so wrap it
        // in one + a Done button when presenting from a push, like the booking sheet.
        .sheet(item: $offersPresentation) { presentation in
            NavigationStack {
                PriorityOffersView(highlightRecipientId: presentation.highlight)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { offersPresentation = nil }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        #if DEBUG
        .fullScreenCover(isPresented: $debugShowBookings) {
            NavigationStack {
                AppointmentsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { debugShowBookings = false }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        .fullScreenCover(isPresented: $debugShowSettings) {
            NavigationStack {
                ClientSettingsHubView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { debugShowSettings = false }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        .fullScreenCover(isPresented: $debugShowSettingsProfile) {
            NavigationStack {
                ClientProfileEditView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { debugShowSettingsProfile = false }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        .fullScreenCover(isPresented: Binding(
            get: { debugPushedLookId != nil },
            set: { if !$0 { debugPushedLookId = nil } }
        )) {
            NavigationStack {
                if let id = debugPushedLookId {
                    LookDetailView(lookId: id)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Done") { debugPushedLookId = nil }
                                    .tint(BrandColor.textSecondary)
                            }
                        }
                }
            }
            .tint(BrandColor.accent)
        }
        #endif
    }

    /// Resolve a push deep link to a concrete destination and present it, then
    /// clear it from the session so it isn't re-handled. Booking ids are resolved
    /// from the bookings list (the same source the in-app center uses — there's no
    /// standalone GET /bookings/[id]).
    private func routeDeepLink(_ link: PushDeepLink?) async {
        guard let link else { return }
        // A pro-shell target arrived while acting as client (a pro who was in their
        // client workspace). Switch workspaces and leave the link buffered — the
        // pro shell's `.task` consumes it once RootView swaps it in. If the switch
        // doesn't take (not entitled), clear it so no stale link sticks.
        if let role = link.role, role != session.activeRole {
            await session.switchWorkspace(to: role)
            if session.activeRole != role { session.clearPushDeepLink() }
            return
        }
        switch link.target {
        case let .booking(id, step):
            // Carry the `step` so the detail scrolls to that section (consult /
            // aftercare); unknown steps just open at the top.
            if let buckets = try? await session.client.bookings.fetch() {
                let all = buckets.upcoming + buckets.pending + buckets.prebooked + buckets.past
                deepLinkBookingStep = step
                deepLinkBooking = all.first { $0.id == id }
            }
        case let .thread(id):
            deepLinkThread = try? await session.client.messages.thread(id: id)
        case let .look(id, book):
            // A shared look (Universal Link) or a look push → the native detail.
            deepLinkLook = LookPresentation(id: id, book: book)
        case let .publicClient(handle):
            // A shared /u/{handle} link → the native creator profile.
            deepLinkPublicClient = PublicClientPresentation(handle: handle)
        case let .publicPro(professionalId):
            // A shared /professionals/{id} link → the native pro profile. This is
            // the link the profile's own Share control emits.
            deepLinkPublicPro = PublicProPresentation(professionalId: professionalId)
        case let .offers(accept):
            // The full priority-offers + waitlist-offers screen (countdown claim/
            // pass + pro-proposed-time confirm/decline). `accept` floats + highlights
            // the offer the push was about.
            offersPresentation = OffersPresentation(highlight: accept)
        case .referrals:
            // Referrals live under the Me tab.
            tab = .me
        case .activity:
            showActivity = true
        case .chartAccess:
            // A pro asked to read this client's chart. Present the consent
            // surface itself — this push is a QUESTION, and dropping the client
            // on Home (which is where it landed before `.chartAccess` existed)
            // leaves them with the buzz and no way to answer it.
            showChartAccess = true
        case .clientHome:
            tab = .home
        // Pro-shell targets are handled by the workspace switch above; unreachable
        // here, but the switch must stay exhaustive.
        case .proBooking, .proReviews, .membership, .proProfile, .proCalendar, .proHome:
            break
        }
        session.clearPushDeepLink()
    }

    private func pollBadge() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { await refreshBadge() }
        }
    }

    private func refreshBadge() async {
        let count = (try? await session.client.messages.unreadCount()) ?? 0
        messagesBadge = count <= 0 ? nil : (count > 9 ? "9+" : "\(count)")
    }
}