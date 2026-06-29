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
    @State private var tab: ProTab.ID = .calendar   // pros land on Calendar (web /pro → /pro/calendar)
    @State private var messagesBadge: String?
    @State private var proSession: ProSessionModel?

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
            LooksView()
                .tag(ProTab.ID.looks)

            ProCalendarView()
                .tag(ProTab.ID.calendar)

            InboxView()
                .tag(ProTab.ID.messages)

            ProProfileTabView()
                .tag(ProTab.ID.profile)
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ProTabBar(selected: $tab, session: proSession, messagesBadge: messagesBadge)
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
