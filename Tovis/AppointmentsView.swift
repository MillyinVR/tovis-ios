// Appointments — the client's bookings, bucketed exactly like the web bookings
// page (GET /api/v1/client/bookings). Each booking taps through to a detail view.
import SwiftUI
import TovisKit

struct AppointmentsView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded(ClientBookingBuckets)
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
                    case let .loaded(buckets):
                        content(buckets)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(BrandColor.bgPrimary.ignoresSafeArea())
            .navigationTitle("Appointments")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
            .refreshable { await load() }
            .task {
                if case .loading = phase { await load() }
            }
        }
        .tint(BrandColor.accent)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ buckets: ClientBookingBuckets) -> some View {
        bookingSection("Upcoming", buckets.upcoming)
        bookingSection("Needs your attention", buckets.pending)
        bookingSection("Pre-booked", buckets.prebooked)

        if !buckets.waitlist.isEmpty {
            BrandSection(title: "Waitlist") {
                VStack(spacing: 10) {
                    ForEach(buckets.waitlist) { WaitlistEntryRow(entry: $0) }
                }
            }
        }

        bookingSection("Past", buckets.past)

        if isEmpty(buckets) {
            emptyState
        }
    }

    @ViewBuilder
    private func bookingSection(_ title: String, _ bookings: [ClientBooking]) -> some View {
        if !bookings.isEmpty {
            BrandSection(title: title, trailing: "\(bookings.count)") {
                VStack(spacing: 10) {
                    ForEach(bookings) { booking in
                        NavigationLink {
                            BookingDetailView(booking: booking, onDecision: { await load() })
                        } label: {
                            BookingRow(booking: booking)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func isEmpty(_ b: ClientBookingBuckets) -> Bool {
        b.upcoming.isEmpty && b.pending.isEmpty && b.prebooked.isEmpty &&
            b.past.isEmpty && b.waitlist.isEmpty
    }

    // MARK: - States

    private var loadingState: some View {
        HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
            .padding(.top, 80)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No appointments yet")
                .font(BrandFont.display(20, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text("Once you book, your appointments show up here.")
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await load() }
            } label: {
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

    private func load() async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            let buckets = try await session.client.bookings.fetch()
            phase = .loaded(buckets)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Something went wrong. Please try again.")
        }
    }
}

// MARK: - Rows

private struct BookingRow: View {
    let booking: ClientBooking

    var body: some View {
        BrandSurface {
            HStack(spacing: 12) {
                if let pro = booking.professional {
                    BrandAvatar(name: pro.displayName, size: 44)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(booking.display.title)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .lineLimit(1)
                    Text(Wire.dateTime(booking.scheduledFor, timeZone: booking.timeZone))
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                    if let pro = booking.professional {
                        Text(pro.displayName)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if booking.hasPendingConsultationApproval {
                        BrandPill(text: "Review", tint: BrandColor.gold)
                    } else if let status = booking.status {
                        BrandPill(text: status.capitalized, tint: statusTone(status))
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
    }
}

private struct WaitlistEntryRow: View {
    let entry: BookingWaitlistEntry

    var body: some View {
        BrandSurface {
            HStack(spacing: 12) {
                if let pro = entry.professional {
                    BrandAvatar(name: pro.displayName, size: 44)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.service?.name ?? "Any service")
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    if let pro = entry.professional {
                        Text(pro.displayName)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                }
                Spacer()
                BrandPill(text: "Waitlisted", tint: BrandColor.iris)
            }
        }
    }
}
