// Pro Calendar — the pro's schedule agenda (GET /api/v1/pro/calendar), the native
// counterpart of the web `/pro/calendar`. v1 is a grouped agenda: a stats header
// (today's bookings · pending requests), a "Pending requests" section, then the
// upcoming bookings + blocks grouped by day. Tapping a booking opens its live-
// session hub. (The full day/week grid + block editing is a later phase.)
import SwiftUI
import TovisKit

struct ProCalendarView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded(ProCalendarResponse)
        case failed(String)
    }

    @State private var phase: Phase = .loading

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch phase {
                    case .loading:
                        loadingState
                    case let .failed(message):
                        errorState(message)
                    case let .loaded(data):
                        content(data)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 120)   // clear the raised footer
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .refreshable { await load() }
            .task { if case .loading = phase { await load() } }
            // Live-sync: a booking made on web (or by a client) shows here.
            .onChange(of: session.refreshTick) { Task { await load() } }
            .task { await poll() }
            .tint(BrandColor.accent)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ data: ProCalendarResponse) -> some View {
        statsHeader(data.stats)

        if !data.management.pendingRequests.isEmpty {
            BrandSection(title: "Pending requests", trailing: "\(data.management.pendingRequests.count)") {
                VStack(spacing: 10) {
                    ForEach(data.management.pendingRequests) { row(for: $0, zone: data.viewportTimeZone) }
                }
            }
        }

        let upcoming = data.events.filter { $0.isBooking || $0.isBlock }
        if upcoming.isEmpty {
            emptyState
        } else {
            ForEach(groupedByDay(upcoming), id: \.key) { group in
                BrandSection(title: dayHeading(group.key)) {
                    VStack(spacing: 10) {
                        ForEach(group.events) { row(for: $0, zone: data.viewportTimeZone) }
                    }
                }
            }
        }
    }

    private func statsHeader(_ stats: ProCalendarStats) -> some View {
        HStack(spacing: 12) {
            statTile("\(stats.todaysBookings)", "Today")
            statTile("\(stats.pendingRequests)", "Requests")
            if let hours = stats.availableHours {
                statTile(hoursLabel(hours), "Open")
            }
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(BrandFont.display(24, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text(label.uppercased())
                    .font(BrandFont.mono(10))
                    .tracking(0.8)
                    .foregroundStyle(BrandColor.textMuted)
            }
        }
    }

    @ViewBuilder
    private func row(for event: ProCalendarEvent, zone: String?) -> some View {
        if event.isBooking {
            NavigationLink {
                ProSessionHubView(bookingId: event.id)
            } label: {
                ProCalendarEventRow(event: event, zone: zone)
            }
            .buttonStyle(.plain)
        } else {
            ProCalendarEventRow(event: event, zone: zone)   // blocks aren't tappable
        }
    }

    // MARK: - Grouping

    private struct DayGroup { let key: String; let events: [ProCalendarEvent] }

    private func groupedByDay(_ events: [ProCalendarEvent]) -> [DayGroup] {
        let sorted = events.sorted { $0.startsAt < $1.startsAt }
        var order: [String] = []
        var byDay: [String: [ProCalendarEvent]] = [:]
        for e in sorted {
            if byDay[e.localDateKey] == nil { order.append(e.localDateKey) }
            byDay[e.localDateKey, default: []].append(e)
        }
        return order.map { DayGroup(key: $0, events: byDay[$0] ?? []) }
    }

    /// "YYYY-MM-DD" → "Wed, Jul 15" (or "Today" / "Tomorrow").
    private func dayHeading(_ key: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: key) else { return key }

        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }

        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US")
        out.dateFormat = "EEE, MMM d"
        return out.string(from: date)
    }

    private func hoursLabel(_ hours: Double) -> String {
        hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }

    // MARK: - States

    private var loadingState: some View {
        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
            .padding(.top, 80)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("Nothing on the books")
                .font(BrandFont.display(20, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("New bookings and requests will appear here.")
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
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
                    .padding(.vertical, 12)
                    .padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    // MARK: - Load

    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { await load() }
        }
    }

    private func load() async {
        do {
            let data = try await session.client.proCalendar.calendar()
            phase = .loaded(data)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your calendar. Please try again.")
        }
    }
}

// MARK: - Row

private struct ProCalendarEventRow: View {
    let event: ProCalendarEvent
    let zone: String?

    var body: some View {
        BrandSurface {
            HStack(spacing: 12) {
                BrandAvatar(name: event.clientName, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    Text(Wire.dateTime(event.startsAt, timeZone: event.timeZone ?? zone))
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                    if event.isBooking {
                        Text(event.clientName)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    BrandPill(text: statusLabel, tint: statusTone(event.status))
                    if event.isBooking {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }
            }
        }
    }

    private var statusLabel: String {
        if event.isBlock { return "Blocked" }
        return event.status.capitalized
    }
}
