// Appointments — the client's bookings, bucketed exactly like the web bookings
// page (GET /api/v1/client/bookings). Each booking taps through to a detail view.
//
// Also carries the aftercare strip the web page has had all along
// (AppointmentsList.tsx): the last few summaries, each opening its visit focused
// on the aftercare step, plus an "All aftercare" hand-off to AftercareInboxView.
// Without it, AftercareInboxView's ONLY entry on iOS was the Home action card —
// and that card is doubly gated server-side: it appears solely for
// AFTERCARE_PAYMENT_DUE, and a PENDING_CONSULTATION outranks it in the same
// single action slot (getClientHomeData). So aftercare with nothing left to pay
// — the normal end state — had no route at all.
import SwiftUI
import TovisKit

/// How many summaries the strip shows before handing off to the full inbox.
/// Mirrors `AFTERCARE_STRIP_SIZE` in the web AppointmentsList.
private let aftercareStripSize = 3

struct AppointmentsView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded(ClientBookingBuckets)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    /// Aftercare rides alongside the buckets. Supplementary, so it loads on its
    /// own and a failure here leaves the bookings list intact rather than
    /// blanking the screen over a strip.
    @State private var aftercare: [ClientAftercareInboxItem] = []
    /// The booking a tapped aftercare row resolved to — drives the detail push.
    @State private var aftercareNav: ClientBookingNav?
    /// The aftercare row currently resolving its booking, for a spinner.
    @State private var resolvingAftercare: String?
    @State private var aftercareResolveFailed = false

    // Owns no NavigationStack: it is PUSHED inside a host tab's stack (Home / Me)
    // as well as rooting the Bookings tab, where MainTabView supplies the stack.
    // Adding one here would nest stacks on the pushed paths.
    var body: some View {
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
        // Same destination the web aftercare rows link to
        // (/client/bookings/{id}?step=aftercare), and the same one
        // AftercareInboxView pushes.
        .navigationDestination(item: $aftercareNav) { nav in
            BookingDetailView(booking: nav.booking, focusStep: "aftercare")
        }
        .alert("Couldn’t open that aftercare", isPresented: $aftercareResolveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try again in a moment.")
        }
        .refreshable { await load() }
        .task {
            if case .loading = phase { await load() }
        }
        // Live-sync: refetch on foreground / Realtime signal, and poll gently
        // (this is the "leave it open on the salon computer" screen).
        .onChange(of: session.refreshTick) { Task { await load() } }
        .task { await poll() }
        .tint(BrandColor.accent)
    }

    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { await load() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ buckets: ClientBookingBuckets) -> some View {
        bookingSection("Upcoming", buckets.upcoming)
        bookingSection("Needs your attention", buckets.pending)

        aftercareSection

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

    /// The aftercare strip + its hand-off to the full inbox. Ordered right after
    /// "Needs your attention" to match the web page's section order.
    @ViewBuilder
    private var aftercareSection: some View {
        if !aftercare.isEmpty {
            // No count in the header, deliberately, exactly as the web does it: a
            // capped strip showing "3" would read as "you have three" when there
            // may be thirty. The link below is the honest total.
            BrandSection(title: "Aftercare") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(aftercare.prefix(aftercareStripSize)) { item in
                        AftercareStripRow(
                            item: item,
                            busy: resolvingAftercare == item.id,
                            disabled: item.bookingId == nil || resolvingAftercare != nil,
                            onOpen: { Task { await openAftercare(item) } }
                        )
                    }

                    // UNCONDITIONAL — the whole point of this strip. The inbox
                    // must not be gated on how much aftercare a client has.
                    NavigationLink { AftercareInboxView() } label: {
                        HStack(spacing: 4) {
                            Text("All aftercare")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
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

    /// Aftercare counts toward "is there anything here" — same as the web list. A
    /// summary that outlives its booking row would otherwise sit underneath a
    /// "No appointments yet" card claiming the screen is empty.
    private func isEmpty(_ b: ClientBookingBuckets) -> Bool {
        b.upcoming.isEmpty && b.pending.isEmpty && b.prebooked.isEmpty &&
            b.past.isEmpty && b.waitlist.isEmpty && aftercare.isEmpty
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
            return
        } catch {
            phase = .failed("Something went wrong. Please try again.")
            return
        }
        // Supplementary, and deliberately after the buckets: the strip failing
        // must not take the bookings list down with it, so it degrades to no
        // strip. The inbox tab remains reachable either way.
        aftercare = (try? await session.client.bookings.aftercareInbox()) ?? []
    }

    /// Resolve the row's booking, then push its detail focused on aftercare —
    /// the same two-step AftercareInboxView does, and for the same reason: the
    /// inbox row carries only a booking id and there is no single-booking client
    /// GET (see `BookingsService.booking(id:)`).
    private func openAftercare(_ item: ClientAftercareInboxItem) async {
        guard let bookingId = item.bookingId, resolvingAftercare == nil else { return }
        resolvingAftercare = item.id
        defer { resolvingAftercare = nil }
        do {
            if let booking = try await session.client.bookings.booking(id: bookingId) {
                aftercareNav = ClientBookingNav(booking: booking)
            } else {
                aftercareResolveFailed = true
            }
        } catch {
            aftercareResolveFailed = true
        }
    }
}

// MARK: - Aftercare strip row

/// A compact summary row. The full card — before/after pair, rebook hint, note —
/// lives in AftercareInboxView, which is one tap away; duplicating it here would
/// make the strip taller than the bookings it sits among.
private struct AftercareStripRow: View {
    let item: ClientAftercareInboxItem
    let busy: Bool
    let disabled: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            BrandSurface(tint: BrandColor.bgSecondary) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(item.title)
                                .font(BrandFont.body(15, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                                .lineLimit(1)
                            if item.unread {
                                BrandPill(text: "NEW", tint: BrandColor.accent)
                            }
                        }
                        if let scheduledFor = item.scheduledFor, !scheduledFor.isEmpty {
                            Text(Wire.dateOnly(scheduledFor, timeZone: item.timeZone))
                                .font(BrandFont.body(13))
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                        Text(item.proName)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    if busy {
                        ProgressView().tint(BrandColor.accent).scaleEffect(0.8)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(BrandColor.textMuted)
                    }
                }
            }
            .opacity(item.bookingId == nil ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
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
                        // `.capitalized` rendered "In_Progress" / "No_Show" (B10).
                        BrandPill(
                            text: BookingStatusPresentation.label(status),
                            tint: statusTone(status))
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
