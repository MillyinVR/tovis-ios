// Pro Bookings — the native counterpart of the web `/pro/bookings`
// (app/pro/bookings/page.tsx), backed by GET /api/v1/pro/bookings (tovis-app
// PR #435). Stats (Today / In session / Payment due) + filter pills + the
// Today / Upcoming / Past / Cancelled sections, each row tapping through to the
// booking detail. Lives on the Overview home's Bookings tab.
import SwiftUI
import TovisKit

struct ProBookingsListView: View {
    @Environment(SessionModel.self) private var session

    // web FilterPills: All · Pending · Accepted · Active · Completed · Cancelled.
    enum Filter: String, CaseIterable, Identifiable {
        case all = "ALL"
        case pending = "PENDING"
        case accepted = "ACCEPTED"
        case inProgress = "IN_PROGRESS"
        case completed = "COMPLETED"
        case cancelled = "CANCELLED"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "All"
            case .pending: return "Pending"
            case .accepted: return "Accepted"
            case .inProgress: return "Active"
            case .completed: return "Completed"
            case .cancelled: return "Cancelled"
            }
        }
        /// Query value for the API (nil = default ALL view).
        var apiValue: String? { self == .all ? nil : rawValue }
    }

    private enum Phase {
        case loading
        case loaded(ProBookingsListResponse)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var filter: Filter = .all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if case let .loaded(data) = phase {
                    statsRow(data.stats)
                }
                filterPills

                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 50)
                case let .failed(message):
                    errorState(message)
                case let .loaded(data):
                    sections(data)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 120)   // clear the raised footer
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
        .onChange(of: filter) { Task { await load() } }
        .onChange(of: session.refreshTick) { Task { await load() } }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ProNewBookingView()
                } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(BrandColor.accent)
                }
            }
        }
    }

    // MARK: - Stats

    private func statsRow(_ stats: ProBookingsListStats) -> some View {
        HStack(spacing: 10) {
            statCard(value: stats.today, label: "Today", tint: BrandColor.textPrimary)
            statCard(value: stats.inSession, label: "In session", tint: BrandColor.accent)
            statCard(value: stats.paymentDue, label: "Payment due", tint: BrandColor.gold)
        }
    }

    private func statCard(value: Int, label: String, tint: Color) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(BrandFont.display(24, .bold))
                    .foregroundStyle(tint)
                Text(label.uppercased())
                    .font(BrandFont.mono(9))
                    .tracking(1.4)
                    .foregroundStyle(BrandColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Filter

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { item in
                    let active = item == filter
                    Button { filter = item } label: {
                        Text(item.label)
                            .font(BrandFont.body(12, .bold))
                            .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textPrimary)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            .background(active ? BrandColor.accent : BrandColor.bgSecondary)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(BrandColor.textMuted.opacity(active ? 0 : 0.18), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func sections(_ data: ProBookingsListResponse) -> some View {
        if filter != .cancelled {
            section("Today", data.today)
            section("Upcoming", data.upcoming)
            section("Past", data.past)
        }
        if filter == .all || filter == .cancelled {
            section("Cancelled", data.cancelled)
        }
    }

    private func section(_ title: String, _ items: [ProBookingListItem]) -> some View {
        BrandSection(title: title, trailing: items.isEmpty ? nil : "\(items.count) total") {
            if items.isEmpty {
                Text("No bookings here yet.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textMuted)
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { booking in
                        NavigationLink {
                            ProBookingDetailView(bookingId: booking.id)
                        } label: {
                            bookingCard(booking)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func bookingCard(_ booking: ProBookingListItem) -> some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(booking.serviceName)
                        .font(BrandFont.body(15, .bold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    BrandPill(text: booking.statusLabel, tint: statusTone(booking.status))
                    if booking.needsCloseout {
                        BrandPill(text: "Payment due", tint: BrandColor.gold)
                    }
                    Spacer(minLength: 0)
                }

                if !booking.addOnNames.isEmpty {
                    Text("+ \(booking.addOnNames.joined(separator: ", "))")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    BrandAvatar(name: booking.client.fullName, size: 24)
                    Text(booking.client.fullName)
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.textSecondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 11))
                        .foregroundStyle(BrandColor.textMuted)
                    Text(booking.durationMinutes > 0
                        ? "\(booking.whenLabel) · \(booking.durationMinutes) min"
                        : booking.whenLabel)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }

                if let total = Wire.money(booking.total) {
                    Text("Total: \(total)")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }

                if let address = booking.location.formattedAddress, !address.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 11))
                            .foregroundStyle(booking.location.isMobile ? BrandColor.accent : BrandColor.textMuted)
                        if booking.location.isMobile {
                            Text("MOBILE")
                                .font(BrandFont.mono(8))
                                .tracking(1.0)
                                .foregroundStyle(BrandColor.accent)
                        }
                        Text(address)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textSecondary)
                            .lineLimit(1)
                    }
                }

                if booking.isInProgress, let step = booking.sessionStep {
                    Text("Session · \(step.replacingOccurrences(of: "_", with: " "))")
                        .font(BrandFont.mono(9))
                        .tracking(1.0)
                        .foregroundStyle(BrandColor.accent)
                }
            }
        }
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
        .padding(.top, 50)
    }

    private func load() async {
        do {
            let data = try await session.client.proBookings.list(status: filter.apiValue)
            phase = .loaded(data)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your bookings.")
        }
    }
}
