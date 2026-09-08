// The pro Overview home — the native host for the web pro top-header
// (app/pro/ProHeader.tsx) and its secondary tab strip. On web the header is
// global chrome over every pro page; natively the footer keeps the web
// `ProSessionFooter` 5 slots, so the header tabs (Overview · Reviews · Aftercare
// · Bookings · Last Minute · Locations) live here on a dedicated home reached
// from the Calendar bar's Home control (the pro lands on Calendar, like web).
//
// The strip swaps the body in place (like switching web routes). Each tab body
// is filled in across the H2–H7 increments; until then they show a short
// placeholder. The bell opens the existing `ProNotificationsView`.
import SwiftUI
import TovisKit

struct ProOverviewHomeView: View {
    @Environment(SessionModel.self) private var session

    @State private var selection: ProHeaderTab = Self.launchTab

    /// The header tab a launch starts on — Finance, unless a DEBUG build was
    /// launched with `TOVIS_DEBUG_OPEN_PRO_TAB` naming another one.
    ///
    /// DEBUG ONLY, and for exactly the reason `ProMainTabView.launchTab` gives
    /// for its own key: this machine cannot drive the simulator with synthetic
    /// taps, so a screen behind a header tap is a screen nobody ever looks at.
    /// The Bookings tab is where the P7a-4 prep flag renders, and it was two
    /// taps past anything a script could reach.
    ///
    /// Accepts a `ProHeaderTab` raw value (`overview` · `reviews` · `aftercare`
    /// · `bookings` · `lastMinute` · `locations`); anything else lands on
    /// Finance as usual.
    ///
    ///     SIMCTL_CHILD_TOVIS_DEBUG_OPEN_PRO_TAB=bookings xcrun simctl launch …
    ///
    /// Read as the STATE'S INITIAL VALUE rather than applied in `onAppear`, the
    /// same way `ProMainTabView` learned to: the shell swaps view identity when
    /// a live pro session resolves, which resets `@State` and threw an onAppear
    /// assignment away about half the time.
    private static var launchTab: ProHeaderTab {
        #if DEBUG
        let raw = ProcessInfo.processInfo.environment["TOVIS_DEBUG_OPEN_PRO_TAB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, let wanted = ProHeaderTab(rawValue: raw) { return wanted }
        #endif
        return .overview
    }
    @State private var showNotifications = false
    @State private var hasUnread = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProTopBar(title: selection.title, hasUnread: hasUnread) {
                    showNotifications = true
                }
                // Not-bookable nudge → opens the onboarding readiness checklist.
                // Renders nothing once the pro is fully set up (parity with web's
                // ProReadinessBanner across the pro shell).
                ProReadinessBanner()
                ProHeaderTabsBar(selection: $selection)
                tabBody
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .task { await loadSummary() }
            .onChange(of: session.refreshTick) { Task { await loadSummary() } }
            .sheet(isPresented: $showNotifications, onDismiss: { Task { await loadSummary() } }) {
                ProNotificationsView()
            }
        }
        .tint(BrandColor.accent)
    }

    @ViewBuilder
    private var tabBody: some View {
        switch selection {
        case .overview:
            // Folded Finance & Tax hub (web repointed Overview → /pro/finance).
            // Its Overview sub-tab still renders the retained performance stats.
            ProFinanceView()
        case .consults:
            ProConsultQueueView()
        case .reviews:
            ProReviewsListView()
        case .aftercare:
            ProAftercareListView()
        case .bookings:
            ProBookingsListView()
        case .lastMinute:
            ProLastMinuteView()
        case .locations:
            ProLocationsView()
        }
    }

    private func placeholder(_ message: String) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(message)
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 30)
            .padding(.top, 64)
        }
    }

    private func loadSummary() async {
        if let summary = try? await session.client.proNotifications.summary() {
            hasUnread = summary.hasUnread
        }
    }
}
