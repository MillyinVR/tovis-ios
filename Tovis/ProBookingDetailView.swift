// Pro booking detail — the native port of the web `/pro/bookings/[id]` page.
// The calendar agenda is the list; tapping a booking opens this. It reads the
// authoritative detail (`GET /pro/bookings/[id]`) and offers the pro's management
// actions: ACCEPT a pending request, CANCEL (auto-refunds the client), propose the
// client's next appointment (REBOOK), and an entry into the live-session hub.
import SwiftUI
import TovisKit

struct ProBookingDetailView: View {
    @Environment(SessionModel.self) private var session
    @Environment(\.dismiss) private var dismiss
    let bookingId: String

    private enum Phase {
        case loading
        case loaded(ProBookingDetail)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var working = false
    @State private var actionError: String?

    // Cancel
    @State private var showCancelConfirm = false

    // Rebook proposer
    @State private var showRebook = false
    @State private var rebookDate = Date()
    @State private var rebooking = false
    @State private var rebookError: String?
    @State private var rebookProposedLocally = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 80)
                case let .failed(message):
                    errorState(message)
                case let .loaded(booking):
                    content(booking)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 48)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Appointment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .task { if case .loading = phase { await load() } }
        .onChange(of: session.refreshTick) { Task { await load() } }
        .tint(BrandColor.accent)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ booking: ProBookingDetail) -> some View {
        headerCard(booking)
        contactCard(booking)

        if !booking.serviceItems.isEmpty {
            BrandSection(title: "Services") {
                VStack(spacing: 10) {
                    ForEach(booking.serviceItems) { item in
                        lineRow(
                            name: item.isAddOn ? "+ \(item.serviceName)" : item.serviceName,
                            detail: "\(item.durationMinutesSnapshot) min",
                            amount: item.priceSnapshot
                        )
                    }
                }
            }
        }

        totalsCard(booking)

        if let actionError {
            Text(actionError)
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.ember)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        // Accept a pending request.
        if booking.isPending {
            Button { Task { await accept() } } label: {
                primaryLabel(working ? "Accepting…" : "Accept request")
            }
            .disabled(working)
        }

        // Live session — open the session hub (start/finish, photos, steps).
        if booking.isAccepted || booking.isInProgress {
            NavigationLink {
                ProSessionHubView(bookingId: booking.id)
            } label: {
                primaryLabel(booking.isInProgress ? "Resume session" : "Open session")
            }
        }

        // Propose the client's next appointment.
        if !booking.isTerminal {
            rebookCard(booking)
        }

        // Cancel (PENDING / ACCEPTED only).
        if booking.isCancellable {
            cancelCard
        }
    }

    // MARK: - Cards

    private func headerCard(_ booking: ProBookingDetail) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    BrandAvatar(name: booking.client.fullName, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(booking.title)
                            .font(BrandFont.body(18, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text(booking.client.fullName)
                            .font(BrandFont.body(14))
                            .foregroundStyle(BrandColor.textSecondary)
                    }
                    Spacer()
                }

                Divider().overlay(BrandColor.textMuted.opacity(0.15))

                infoRow(icon: "calendar",
                        text: Wire.dateTime(booking.scheduledFor, timeZone: booking.timeZone))
                infoRow(icon: "clock", text: "\(booking.totalDurationMinutes) min")
                if let place = locationLabel(booking) {
                    infoRow(icon: "mappin.and.ellipse", text: place)
                }

                BrandPill(text: booking.status.capitalized, tint: statusTone(booking.status))
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func contactCard(_ booking: ProBookingDetail) -> some View {
        let email = booking.client.email
        let phone = booking.client.phone
        if email != nil || phone != nil {
            BrandSection(title: "Client") {
                VStack(spacing: 10) {
                    if let phone {
                        contactRow(icon: "phone.fill", label: phone, url: URL(string: "tel:\(phone.filter { !$0.isWhitespace })"))
                    }
                    if let email {
                        contactRow(icon: "envelope.fill", label: email, url: URL(string: "mailto:\(email)"))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func contactRow(icon: String, label: String, url: URL?) -> some View {
        if let url {
            Link(destination: url) { contactRowBody(icon: icon, label: label, tappable: true) }
        } else {
            contactRowBody(icon: icon, label: label, tappable: false)
        }
    }

    private func contactRowBody(icon: String, label: String, tappable: Bool) -> some View {
        BrandSurface {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(BrandColor.accent)
                    .frame(width: 24)
                Text(label)
                    .font(BrandFont.body(14))
                    .foregroundStyle(tappable ? BrandColor.accent : BrandColor.textSecondary)
                Spacer()
            }
        }
    }

    private func totalsCard(_ booking: ProBookingDetail) -> some View {
        BrandSurface {
            HStack {
                Text("Subtotal")
                    .font(BrandFont.body(16, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Spacer()
                Text(Wire.money(booking.subtotalSnapshot) ?? "—")
                    .font(BrandFont.body(16, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
            }
        }
    }

    @ViewBuilder
    private func rebookCard(_ booking: ProBookingDetail) -> some View {
        if rebookProposedLocally {
            BrandSurface(tint: BrandColor.emerald.opacity(0.14)) {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.checkmark").foregroundStyle(BrandColor.emerald)
                    Text("Next appointment proposed")
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Spacer()
                }
            }
        } else {
            BrandSurface {
                VStack(alignment: .leading, spacing: 12) {
                    Button { withAnimation { showRebook.toggle() } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "calendar.badge.plus").foregroundStyle(BrandColor.accent)
                            Text("Propose next appointment")
                                .font(BrandFont.body(15, .semibold))
                                .foregroundStyle(BrandColor.textPrimary)
                            Spacer()
                            Image(systemName: showRebook ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(BrandColor.textMuted)
                        }
                    }
                    .buttonStyle(.plain)

                    if showRebook {
                        DatePicker(
                            "When",
                            selection: $rebookDate,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .datePickerStyle(.compact)
                        .tint(BrandColor.accent)

                        Button { Task { await proposeRebook(booking) } } label: {
                            Group {
                                if rebooking { ProgressView().tint(BrandColor.onAccent) }
                                else { Text("Send proposal").font(BrandFont.body(15, .semibold)) }
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .foregroundStyle(BrandColor.onAccent)
                            .background(BrandColor.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(rebooking)

                        if let rebookError {
                            Text(rebookError)
                                .font(BrandFont.body(12)).foregroundStyle(BrandColor.ember)
                        }
                    }
                }
            }
        }
    }

    private var cancelCard: some View {
        Button { showCancelConfirm = true } label: {
            Group {
                if working { ProgressView().tint(BrandColor.ember) }
                else { Text("Cancel appointment").font(BrandFont.body(16, .semibold)) }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 15)
            .foregroundStyle(BrandColor.ember)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(BrandColor.ember.opacity(0.4), lineWidth: 1)
            )
        }
        .disabled(working)
        .confirmationDialog(
            "Cancel this appointment?",
            isPresented: $showCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Cancel appointment", role: .destructive) { Task { await cancel() } }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("The client is notified and any payment is refunded.")
        }
    }

    // MARK: - Bits

    private func infoRow(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(BrandFont.body(14))
            .foregroundStyle(BrandColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lineRow(name: String, detail: String, amount: String?) -> some View {
        BrandSurface {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(detail)
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textMuted)
                }
                Spacer()
                Text(Wire.money(amount) ?? "—")
                    .font(BrandFont.body(14, .semibold))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
    }

    private func primaryLabel(_ title: String) -> some View {
        Text(title)
            .font(BrandFont.body(16, .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(BrandColor.onAccent)
            .background(BrandColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func locationLabel(_ booking: ProBookingDetail) -> String? {
        if let addr = booking.locationAddressSnapshot, !addr.isEmpty { return addr }
        switch booking.locationType.uppercased() {
        case "MOBILE": return "Mobile / on location"
        case "SALON": return "In salon"
        default: return nil
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
                    .padding(.vertical, 12).padding(.horizontal, 28)
                    .background(BrandColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    // MARK: - Actions

    private func load() async {
        do {
            let detail = try await session.client.proBookings.detail(bookingId: bookingId)
            phase = .loaded(detail)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load this booking.")
        }
    }

    private func accept() async {
        guard !working else { return }
        working = true
        actionError = nil
        defer { working = false }
        do {
            try await session.client.proBookings.accept(bookingId: bookingId)
            session.signalRefresh()
            await load()
        } catch let error as APIError {
            actionError = error.userMessage
        } catch {
            actionError = "Couldn’t accept the request. Try again."
        }
    }

    private func cancel() async {
        guard !working else { return }
        working = true
        actionError = nil
        defer { working = false }
        do {
            try await session.client.proBookings.cancel(bookingId: bookingId)
            session.signalRefresh()
            dismiss()
        } catch let error as APIError {
            actionError = error.userMessage
        } catch {
            actionError = "Couldn’t cancel the appointment. Try again."
        }
    }

    private func proposeRebook(_ booking: ProBookingDetail) async {
        guard !rebooking else { return }
        rebooking = true
        rebookError = nil
        defer { rebooking = false }
        let iso = ISO8601DateFormatter().string(from: rebookDate)
        do {
            try await session.client.proBookings.rebook(
                bookingId: booking.id, mode: .book, scheduledFor: iso
            )
            rebookProposedLocally = true
            session.signalRefresh()
        } catch let error as APIError {
            rebookError = error.userMessage
        } catch {
            rebookError = "Couldn’t send the proposal. Try again."
        }
    }
}
