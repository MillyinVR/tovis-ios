// Pro calendar management sheet — the native counterpart of the web
// `ManagementModal`. Tapping a stats tile on `ProCalendarView` opens this on the
// matching tab. Four tabs mirror the web:
//   • Booked   — appointments on the schedule for the timeframe the calendar is on
//   • Pending  — every pending request, with approve / deny + a link to the client
//   • Blocked  — personal blocked time for the timeframe (tap to edit, + to add)
//   • Waitlist — the full active waitlist with each client's service + preferred
//                time, and "Offer a time" to book them a matching slot
// Booked / Blocked are derived from the fetched range events (so they follow the
// day/week/month view); Pending / Waitlist come from the management buckets.
import SwiftUI
import TovisKit

enum ProCalendarManagementTab: String, CaseIterable, Identifiable {
    case booked, pending, blocked, waitlist
    var id: String { rawValue }
    var shortTitle: String {
        switch self {
        case .booked: return "Booked"
        case .pending: return "Pending"
        case .blocked: return "Blocked"
        case .waitlist: return "Waitlist"
        }
    }
}

struct ProCalendarManagementSheet: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss

    let events: [ProCalendarEvent]
    let management: ProCalendarManagement
    let timeZone: String?
    /// The calendar's current range label (e.g. "Wed, Jul 2") for Booked/Blocked.
    let headerLabel: String
    /// Re-fetch the parent calendar after an action (approve / deny).
    let onReload: () async -> Void
    /// Route block edit / add to the parent (block editing is itself a sheet).
    let onEditBlock: (ProCalendarEvent) -> Void
    let onAddBlock: () -> Void

    @State var selectedTab: ProCalendarManagementTab
    @State private var pendingBusyId: String?
    @State private var pendingError: String?

    // Navigation targets pushed within this sheet's own stack.
    private struct ChartTarget: Identifiable, Hashable {
        let id = UUID()
        let clientId: String
        let fullName: String
    }
    private struct BookingTarget: Identifiable, Hashable { let id: String }
    private struct OfferTarget: Identifiable, Hashable {
        let id = UUID()
        let clientId: String
        let offeringId: String
    }
    @State private var chartTarget: ChartTarget?
    @State private var bookingTarget: BookingTarget?
    @State private var offerTarget: OfferTarget?
    // Message a client from a row → resolve-or-create the BOOKING/WAITLIST thread
    // and push ThreadView (web parity: the "Message" action). `messageWorkingId`
    // is the row currently resolving (drives its spinner + disables the others).
    @State private var messageNav: MessageThreadNav?
    @State private var messageWorkingId: String?
    // Two-step deny guard: the first "Deny" tap arms this to the row id, swapping in
    // a Cancel / Confirm-deny pair so a client's request isn't declined by a stray
    // tap (web `confirmDenyId`).
    @State private var confirmDenyId: String?

    // MARK: - Derived lists (mirror the web management buckets)

    private var booked: [ProCalendarEvent] {
        events.filter { $0.isBooking && $0.status.uppercased() != "PENDING" }
    }
    private var blocked: [ProCalendarEvent] { events.filter { $0.isBlock } }
    private var pending: [ProCalendarEvent] { management.pendingRequests }
    private var waitlist: [ProCalendarEvent] { management.waitlistToday }

    private func list(for tab: ProCalendarManagementTab) -> [ProCalendarEvent] {
        switch tab {
        case .booked: return booked
        case .pending: return pending
        case .blocked: return blocked
        case .waitlist: return waitlist
        }
    }

    private var title: String {
        switch selectedTab {
        case .booked: return "Booked · \(headerLabel)"
        case .blocked: return "Blocked · \(headerLabel)"
        case .pending: return "Pending requests"
        case .waitlist: return "Waitlist"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabBar
                Divider().overlay(BrandColor.textMuted.opacity(0.15))
                content
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(BrandColor.textPrimary)
                }
            }
            .navigationDestination(item: $chartTarget) { target in
                ProClientChartView(clientId: target.clientId, fullName: target.fullName)
            }
            .navigationDestination(item: $bookingTarget) { target in
                ProBookingDetailView(bookingId: target.id)
            }
            .navigationDestination(item: $offerTarget) { target in
                ProNewBookingView(
                    onCreated: { _ in Task { await onReload() } },
                    prefillClientId: target.clientId,
                    prefillOfferingId: target.offeringId
                )
            }
            .navigationDestination(item: $messageNav) { nav in
                ThreadView(thread: nav.thread)
            }
            .tint(BrandColor.accent)
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ProCalendarManagementTab.allCases) { tab in
                    let active = selectedTab == tab
                    Button {
                        confirmDenyId = nil
                        withAnimation(.easeOut(duration: 0.15)) { selectedTab = tab }
                    } label: {
                        Text("\(tab.shortTitle) (\(list(for: tab).count))")
                            .font(BrandFont.body(13, .semibold))
                            .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textSecondary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            .background(active ? BrandColor.accent : BrandColor.bgSurface)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if selectedTab == .blocked {
                    Button(action: onAddBlock) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                            Text("Block personal time").font(BrandFont.body(14, .semibold))
                        }
                        .foregroundStyle(BrandColor.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(BrandColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if let pendingError, selectedTab == .pending {
                    Text(pendingError)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.ember)
                }

                let rows = list(for: selectedTab)
                if rows.isEmpty {
                    emptyState
                } else {
                    ForEach(rows) { event in
                        row(event)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .padding(.bottom, 40)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(emptyTitle)
                .font(BrandFont.body(15, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(emptyBody)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var emptyTitle: String {
        switch selectedTab {
        case .booked: return "No booked appointments."
        case .pending: return "No pending requests."
        case .blocked: return "No blocked time."
        case .waitlist: return "No one on the waitlist."
        }
    }

    private var emptyBody: String {
        switch selectedTab {
        case .booked: return "Nothing is on your schedule for this view."
        case .pending: return "You're all caught up on requests."
        case .blocked: return "Block time to protect breaks or close off the day."
        case .waitlist: return "Clients who join your waitlist show up here with the times they want."
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ event: ProCalendarEvent) -> some View {
        if event.isBlock {
            blockRow(event)
        } else if event.isWaitlist {
            waitlistRow(event)
        } else {
            bookingRow(event, moderated: selectedTab == .pending)
        }
    }

    private func bookingRow(_ event: ProCalendarEvent, moderated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                BrandAvatar(name: event.clientName, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title.isEmpty ? "Booking" : event.title)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    clientNameView(event)
                    Text(Wire.dateTime(event.startsAt, timeZone: event.timeZone ?? timeZone))
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                        .lineLimit(1)
                }
                Spacer()
            }

            // Primary actions — open (or review, for a pending request) + message.
            HStack(spacing: 10) {
                secondaryButton(moderated ? "Review" : "Open") {
                    bookingTarget = BookingTarget(id: event.id)
                }
                messageButton(event)
                Spacer(minLength: 0)
            }

            // Moderation — pending only; Deny arms a Cancel / Confirm-deny pair.
            if moderated {
                let busy = pendingBusyId == event.id
                HStack(spacing: 10) {
                    if confirmDenyId == event.id {
                        secondaryButton("Cancel") { confirmDenyId = nil }
                            .disabled(busy)
                        secondaryButton(busy ? "Working…" : "Confirm deny", tint: BrandColor.ember) {
                            deny(event)
                        }
                        .disabled(busy)
                    } else {
                        secondaryButton("Deny", tint: BrandColor.ember) { confirmDenyId = event.id }
                            .disabled(busy)
                    }
                    primaryButton(busy ? "Working…" : "Approve") { approve(event) }
                        .disabled(busy)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func waitlistRow(_ event: ProCalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                BrandAvatar(name: event.clientName, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title.isEmpty ? "Service" : event.title)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    clientNameView(event)
                    Text(event.preferenceLabel ?? "Any time")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                        .lineLimit(1)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                if let target = offerTarget(from: event.offerHref) {
                    primaryButton("Offer a time") { offerTarget = target }
                }
                messageButton(event)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func blockRow(_ event: ProCalendarEvent) -> some View {
        Button { onEditBlock(event) } label: {
            HStack(spacing: 12) {
                Image(systemName: "clock.badge.xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(BrandColor.bgSecondary)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title.isEmpty ? "Blocked time" : event.title)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    Text(Wire.dateTime(event.startsAt, timeZone: event.timeZone ?? timeZone))
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BrandColor.textMuted)
            }
            .padding(14)
            .background(BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // Client name → the pro-only chart when the server exposed a clientProfileId;
    // otherwise plain text (no link, matching the web id-leak guard).
    @ViewBuilder
    private func clientNameView(_ event: ProCalendarEvent) -> some View {
        let name = event.clientName.isEmpty ? "Client" : event.clientName
        if let clientProfileId = event.clientProfileId {
            Button {
                chartTarget = ChartTarget(clientId: clientProfileId, fullName: name)
            } label: {
                Text(name)
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.accent)
                    .underline()
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        } else {
            Text(name)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
                .lineLimit(1)
        }
    }

    // MARK: - Buttons

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(BrandColor.onAccent)
                .padding(.vertical, 9)
                .padding(.horizontal, 16)
                .background(BrandColor.accent)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(
        _ label: String, tint: Color = BrandColor.textPrimary, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(BrandFont.body(14, .semibold))
                .foregroundStyle(tint)
                .padding(.vertical, 9)
                .padding(.horizontal, 16)
                .background(BrandColor.bgSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// "Message" the client on a booking or waitlist row — resolves the right
    /// context thread and pushes ThreadView. Disabled (all rows) while one resolves.
    private func messageButton(_ event: ProCalendarEvent) -> some View {
        let working = messageWorkingId == event.id
        return secondaryButton(working ? "Opening…" : "Message") {
            Task { await openThread(for: event) }
        }
        .disabled(messageWorkingId != nil)
    }

    // MARK: - Actions

    private func offerTarget(from href: String?) -> OfferTarget? {
        guard let href, let comps = URLComponents(string: href) else { return nil }
        let items = comps.queryItems ?? []
        guard
            let clientId = items.first(where: { $0.name == "clientId" })?.value,
            let offeringId = items.first(where: { $0.name == "offeringId" })?.value
        else { return nil }
        return OfferTarget(clientId: clientId, offeringId: offeringId)
    }

    /// Resolve-or-create the client thread for a row (BOOKING or WAITLIST context)
    /// and push ThreadView — the native "Message" action (web
    /// `/messages/start?contextType=…`). Waitlist ids carry a "waitlist:" prefix;
    /// the raw entry id is what the WAITLIST resolve expects.
    private func openThread(for event: ProCalendarEvent) async {
        guard messageWorkingId == nil else { return }
        messageWorkingId = event.id
        defer { messageWorkingId = nil }

        let thread: MessageThread?
        if event.isWaitlist {
            let entryId = event.id.hasPrefix("waitlist:")
                ? String(event.id.dropFirst("waitlist:".count))
                : event.id
            thread = try? await session.client.messages.openWaitlistThread(waitlistEntryId: entryId)
        } else {
            thread = try? await session.client.messages.openBookingThread(bookingId: event.id)
        }
        if let thread { messageNav = MessageThreadNav(thread: thread) }
    }

    private func approve(_ event: ProCalendarEvent) {
        confirmDenyId = nil
        runPending(event) { try await session.client.proBookings.accept(bookingId: event.id) }
    }

    private func deny(_ event: ProCalendarEvent) {
        confirmDenyId = nil
        runPending(event) { try await session.client.proBookings.decline(bookingId: event.id) }
    }

    private func runPending(
        _ event: ProCalendarEvent, _ action: @escaping () async throws -> Void
    ) {
        guard pendingBusyId == nil else { return }
        pendingBusyId = event.id
        pendingError = nil
        Task {
            do {
                try await action()
                await onReload()
            } catch let error as APIError {
                pendingError = error.userMessage
            } catch {
                pendingError = "Please try again."
            }
            pendingBusyId = nil
        }
    }
}
