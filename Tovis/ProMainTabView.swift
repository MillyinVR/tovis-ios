// The signed-in PRO shell: the custom Tovis pro footer over the pro surfaces.
//
// Matches the web `ProSessionFooter` 1:1 — Looks · Calendar · [live-session
// center] · Messages · Profile. Like the client shell it keeps a real SwiftUI
// TabView (per-tab state + lazy loading), hides the system bar, and overlays the
// branded `ProTabBar` via safeAreaInset so the raised coin can lift above the bar.
//
// The CENTER is not a tab — it's the live-session button (`ProSessionModel`). Its
// navigation requests (start/finish/navigate) are presented over the shell as the
// session hub for the chosen booking.
import SwiftUI
import TovisKit

struct ProMainTabView: View {
    @Environment(SessionModel.self) private var session
    @State private var tab: ProTab.ID = Self.launchTab   // pros land on Calendar (web `/pro` → `/pro/calendar`); the Overview home is reached via the Calendar bar's Home control
    @State private var messagesBadge: String?
    @State private var proSession: ProSessionModel?
    /// A conversation surfaced by a tapped message push (`/messages/thread/{id}`),
    /// presented over the pro shell. nil when nothing is being deep-linked.
    @State private var deepLinkThread: MessageThread?
    /// A single look surfaced by a tapped share link (`/looks/{id}` Universal
    /// Link) or a look push, presented over the pro shell. A look is role-less —
    /// a pro tapping a shared look opens it without leaving their workspace.
    @State private var deepLinkLook: LookPresentation?
    /// A pro booking surfaced by a `/pro/bookings/{id}` push, presented over the
    /// shell (id-based self-fetch). nil when nothing is being deep-linked.
    @State private var deepLinkProBooking: DeepLinkBookingRef?
    /// The pro reviews list surfaced by a `/pro/reviews[#review-{id}]` push
    /// (review-received); carries the review id to scroll to. nil = not presented.
    @State private var reviewsLink: ReviewsDeepLink?
    /// The membership screen surfaced by a `/pro/membership` push (handle-expiry).
    @State private var showMembership = false
    /// Set while a pushed screen asks for the footer to be hidden (a full-screen
    /// form whose own bottom action bar the footer would sit on top of).
    @State private var footerHidden = false
    /// The standalone (practice) camera, opened from the centre button when no
    /// session is live. Its shots land in the practice library — no booking,
    /// nothing owed.
    @State private var showPracticeCamera = false
    #if DEBUG
    /// DEBUG ONLY — a recurring appointment opened straight from the launch
    /// environment, so the screen can actually be LOOKED AT.
    ///
    /// The same reasoning that produced `DebugSessionSeed`: on this machine the
    /// simulator cannot be driven by synthetic taps (osascript has no assistive
    /// access and the simulator MCP needs a `sudo xcode-select`), and the series
    /// screen is three taps deep. Four parity-epic steps in a row shipped iOS
    /// screens that were build-green, unit-tested and never once seen; that is
    /// the failure this key exists to stop repeating.
    ///
    /// Behind `#if DEBUG`, like the token seed, so it does not exist in a
    /// Release binary. Read ONCE at appear — it is a launch argument, not a
    /// route.
    @State private var debugSeriesId: DebugSeriesRef?

    /// `sheet(item:)` needs identity; a bare String has none.
    private struct DebugSeriesRef: Identifiable, Hashable { let id: String }

    /// DEBUG ONLY — open the practice library straight from the launch
    /// environment, for the same reason as `TOVIS_DEBUG_OPEN_SERIES`: this
    /// machine cannot drive the simulator with synthetic taps, and the library
    /// is three taps behind a camera the simulator does not have. Without this
    /// the screen ships build-green, unit-tested, and never once looked at —
    /// which is precisely the failure that key exists to stop repeating.
    @State private var debugPractice = false
    #endif

    /// The tab a launch starts on — Calendar, unless a DEBUG build was launched
    /// with `TOVIS_DEBUG_OPEN_TAB` naming another one.
    ///
    /// DEBUG ONLY, for the same reason as `TOVIS_DEBUG_OPEN_SERIES` above: this
    /// machine can't drive the simulator with synthetic taps, so a screen behind
    /// a footer tap is a screen nobody ever looks at. Accepts a `ProTab.ID` raw
    /// value (`overview` · `looks` · `calendar` · `messages` · `profile`);
    /// anything else lands on Calendar as usual.
    ///
    ///     SIMCTL_CHILD_TOVIS_DEBUG_OPEN_TAB=profile xcrun simctl launch …
    ///
    /// Read as the STATE'S INITIAL VALUE rather than applied in `onAppear`: the
    /// shell swaps view identity the moment a live pro session resolves, which
    /// resets `@State` — an onAppear assignment got silently thrown away by that
    /// swap about half the time.
    private static var launchTab: ProTab.ID {
        #if DEBUG
        let raw = ProcessInfo.processInfo.environment["TOVIS_DEBUG_OPEN_TAB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let raw, let wanted = ProTab.ID(rawValue: raw) { return wanted }
        #endif
        return .calendar
    }

    var body: some View {
        Group {
            if let proSession {
                shell(proSession)
            } else {
                // Build the session model once we have the client (one per shell).
                Color.clear.onAppear {
                    proSession = ProSessionModel(client: session.client)
                }
            }
        }
    }

    @ViewBuilder
    private func shell(_ proSession: ProSessionModel) -> some View {
        TabView(selection: $tab) {
            ProOverviewHomeView()
                .tag(ProTab.ID.overview)

            LooksView()
                .tag(ProTab.ID.looks)

            ProCalendarView(onHome: { tab = .overview })
                .tag(ProTab.ID.calendar)

            InboxView()
                .tag(ProTab.ID.messages)

            ProProfileTabView()
                .tag(ProTab.ID.profile)
        }
        .toolbar(.hidden, for: .tabBar)
        // A pushed screen with its own bottom bar (e.g. New booking's create bar,
        // a thread's composer) would otherwise be covered by the footer — see
        // `ShellFooterVisibility`. Read the request before installing the bar so
        // the inset collapses to zero while such a screen is up.
        .onPreferenceChange(HidesShellFooterKey.self) { hidden in
            footerHidden = hidden
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !footerHidden {
                ProTabBar(selected: $tab, session: proSession, messagesBadge: messagesBadge,
                          onStandaloneCamera: { showPracticeCamera = true })
            }
        }
        .tint(BrandColor.accent)
        // Keep the live-session state + Messages badge fresh: load on appear, on
        // foreground/Realtime (refreshTick), and a gentle poll — same seams the
        // client shell uses.
        .task { await proSession.load() }
        .task { await refreshBadge() }
        .onChange(of: session.refreshTick) {
            Task { await proSession.load(silent: true) }
            Task { await refreshBadge() }
        }
        .task { await poll(proSession) }
        // Message push deep-link routing (a tapped MESSAGE_RECEIVED push). `.task`
        // catches a cold-launch tap set before this mounted; `.onChange` catches
        // taps while running. Only one shell is mounted per active role, so the
        // client shell handles booking links and this one handles thread links.
        .task { await routeDeepLink(session.pushDeepLink) }
        .onChange(of: session.pushDeepLink) { _, link in
            Task { await routeDeepLink(link) }
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
        // A tapped `/looks/{id}` share link → the single-look detail.
        .sheet(item: $deepLinkLook) { look in
            NavigationStack {
                LookDetailView(lookId: look.id)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { deepLinkLook = nil }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        #if DEBUG
        .sheet(item: $debugSeriesId) { ref in
            NavigationStack {
                ProBookingSeriesView(seriesId: ref.id)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { debugSeriesId = nil }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        .sheet(isPresented: $debugPractice) {
            NavigationStack {
                ProPracticeLibraryView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { debugPractice = false }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["TOVIS_DEBUG_OPEN_PRACTICE"] == "1" {
                debugPractice = true
            }
            // DEBUG ONLY — open the standalone camera itself (not the library),
            // i.e. exactly what the centre button does out of session. The
            // simulator has no camera, so this cannot exercise AVFoundation —
            // but it DOES exercise everything before the first photon: the view
            // being constructed, its `@Environment(SessionModel.self)` lookup,
            // guide resolution, the coach engine starting, the vault sweeps.
            // That is the half of an "instant crash on tap" report that can be
            // reproduced on this machine, and it was not reachable at all.
            if ProcessInfo.processInfo.environment["TOVIS_DEBUG_OPEN_PRACTICE_CAMERA"] == "1" {
                showPracticeCamera = true
            }
            guard debugSeriesId == nil else { return }
            let raw = ProcessInfo.processInfo.environment["TOVIS_DEBUG_OPEN_SERIES"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let raw, !raw.isEmpty { debugSeriesId = DebugSeriesRef(id: raw) }
        }
        #endif
        // A tapped `/pro/bookings/{id}[/aftercare]` push → that booking's detail.
        .sheet(item: $deepLinkProBooking) { ref in
            NavigationStack {
                ProBookingDetailView(bookingId: ref.id, focusStep: ref.step)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { deepLinkProBooking = nil }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
            .onDisappear { Task { await proSession.load(silent: true) } }
        }
        // A tapped `/pro/reviews[#review-{id}]` push (review-received) → the list,
        // scrolled to that review when the id is present.
        .sheet(item: $reviewsLink) { link in
            NavigationStack {
                ProReviewsListView(focusReviewId: link.focusReviewId)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { reviewsLink = nil }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        // A tapped `/pro/membership` push (handle-reservation expiry) → membership.
        .sheet(isPresented: $showMembership) {
            NavigationStack {
                ProMembershipView()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showMembership = false }
                                .tint(BrandColor.textSecondary)
                        }
                    }
            }
            .tint(BrandColor.accent)
        }
        // The standalone camera. Deliberately NOT force-dismissed when a session
        // becomes live mid-shoot: the footer button flips back on its own (it is
        // state-driven), but yanking a running camera out from under a pro is
        // exactly the custody hazard this whole track has been closing. The
        // session button is waiting the moment they close it.
        .fullScreenCover(isPresented: $showPracticeCamera) {
            ProCapturePhotosView(destination: .practice)
        }
        // The booking picker (UPCOMING_PICKER with >1 eligible session).
        .sheet(isPresented: Binding(get: { proSession.pickerOpen }, set: { proSession.pickerOpen = $0 })) {
            ProSessionPickerSheet(session: proSession)
        }
        // The live-session navigation target → present that booking's session hub.
        .sheet(isPresented: Binding(
            get: { proSession.navTarget != nil },
            set: { if !$0 { proSession.clearNavTarget() } }
        )) {
            if let bookingId = proSession.navTarget {
                NavigationStack {
                    ProSessionHubView(bookingId: bookingId)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Done") { proSession.clearNavTarget() }
                                    .tint(BrandColor.textSecondary)
                            }
                        }
                }
                .tint(BrandColor.accent)
                // When the hub closes, refresh the center state (step may have moved).
                .onDisappear { Task { await proSession.load(silent: true) } }
            }
        }
    }

    /// Resolve a tapped push deep link to its pro-shell destination and present it,
    /// then clear it. A client-shell target triggers a workspace switch (leaving the
    /// link buffered for the client shell); anything unresolved is cleared so a
    /// stray link never sticks.
    private func routeDeepLink(_ link: PushDeepLink?) async {
        guard let link else { return }
        // A client-shell target arrived while acting as pro. Switch workspaces and
        // leave the link buffered — the client shell's `.task` consumes it once
        // RootView swaps it in. If the switch doesn't take, clear it.
        if let role = link.role, role != session.activeRole {
            await session.switchWorkspace(to: role)
            if session.activeRole != role { session.clearPushDeepLink() }
            return
        }
        switch link.target {
        case let .thread(id):
            deepLinkThread = try? await session.client.messages.thread(id: id)
        case let .look(id):
            // A shared look (Universal Link) or a look push → the native detail.
            deepLinkLook = LookPresentation(id: id)
        case let .proBooking(id, step):
            // Carry the `step` so the detail scrolls to that section (aftercare);
            // the booking detail also links onward to the session hub.
            deepLinkProBooking = DeepLinkBookingRef(id: id, step: step)
        case let .proReviews(id):
            // Carry the review id (lifted from the `#review-{id}` fragment) so the
            // list scrolls to that review; nil opens the list at the top.
            reviewsLink = ReviewsDeepLink(focusReviewId: id)
        case .membership:
            showMembership = true
        case .proProfile:
            tab = .profile
        case .proCalendar:
            tab = .calendar
        case .proHome:
            tab = .overview
        // Client-shell targets are handled by the workspace switch above;
        // unreachable here, but the switch must stay exhaustive.
        case .booking, .offers, .referrals, .activity, .chartAccess, .clientHome:
            break
        }
        session.clearPushDeepLink()
    }

    private func poll(_ proSession: ProSessionModel) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))   // web POLL_MS = 60s
            if !Task.isCancelled {
                await proSession.load(silent: true)
                await refreshBadge()
            }
        }
    }

    private func refreshBadge() async {
        let count = (try? await session.client.messages.unreadCount()) ?? 0
        messagesBadge = count <= 0 ? nil : (count > 9 ? "9+" : "\(count)")
    }
}

/// Identifiable wrapper so a deep-linked pro booking id can drive a `.sheet(item:)`
/// (a bare `String` isn't `Identifiable`). `step` is the optional deep-link section.
private struct DeepLinkBookingRef: Identifiable { let id: String; let step: String? }

/// Identifiable wrapper for a `/pro/reviews` deep link so it can drive a
/// `.sheet(item:)` even when no specific review is targeted (`focusReviewId == nil`).
private struct ReviewsDeepLink: Identifiable {
    let id = UUID()
    let focusReviewId: String?
}

/// The eligible-booking picker (web's picker sheet in `ProSessionFooter`).
private struct ProSessionPickerSheet: View {
    let session: ProSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(session.eligibleBookings) { booking in
                Button {
                    Task { await session.startSelected(booking.id) }
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(booking.serviceName ?? "Service")
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text(pickerLine(booking))
                            .font(BrandFont.mono(11))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }
                .listRowBackground(BrandColor.bgSurface)
            }
            .scrollContentBackground(.hidden)
            .background(BrandColor.bgPrimary)
            .navigationTitle("Choose booking to start")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(BrandColor.accent)
        .presentationDetents([.medium])
    }

    private func pickerLine(_ b: ProSessionBooking) -> String {
        let client = b.clientName ?? "Client"
        guard let iso = b.scheduledFor else { return client }
        let when = Wire.dateTime(iso, timeZone: nil)
        return when.isEmpty ? client : "\(client) • \(when)"
    }
}
