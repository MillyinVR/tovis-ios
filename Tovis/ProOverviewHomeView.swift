// The pro Overview home — the native host for the web pro top-header
// (app/pro/ProHeader.tsx) and its secondary tab strip. On web the header is
// global chrome over every pro page; natively the footer keeps the web
// `ProSessionFooter` 5 slots, so the header tabs (Overview · Reviews · Aftercare
// · Bookings · Last Minute · Locations) live here on a dedicated home that the
// pro lands on.
//
// The strip swaps the body in place (like switching web routes). Each tab body
// is filled in across the H2–H7 increments; until then they show a short
// placeholder. The bell opens the existing `ProNotificationsView`.
import SwiftUI
import TovisKit

struct ProOverviewHomeView: View {
    @Environment(SessionModel.self) private var session

    @State private var selection: ProHeaderTab = .overview
    @State private var showNotifications = false
    @State private var hasUnread = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProTopBar(title: selection.title, hasUnread: hasUnread) {
                    showNotifications = true
                }
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
            placeholder("Your business at a glance — today's bookings, revenue and ratings. Coming next.")
        case .reviews:
            placeholder("Your most recent client reviews. Coming next.")
        case .aftercare:
            placeholder("Draft, sent and finished aftercare. Coming next.")
        case .bookings:
            placeholder("All your bookings by status — today, upcoming, past and cancelled. Coming next.")
        case .lastMinute:
            placeholder("Last-minute openings, pricing and per-service rules. Coming next.")
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
