// Aftercare inbox — the client's reverse-chrono list of every aftercare summary
// they've received, the native counterpart to the web /client/aftercare page
// (app/client/(gated)/aftercare/page.tsx), backed by GET /api/v1/client/aftercare
// (tovis-app PR #578). Each row shows the visit's before/after, title, pro, date,
// a rebook hint, and the pro's note; tapping it resolves that booking and pushes
// its detail focused on the aftercare step — the same destination as the web
// "Open" CTA (`/client/bookings/{id}?step=aftercare`). Pushed inside the host
// tab's NavigationStack (from the Home aftercare card), so it owns no stack.
import SwiftUI
import TovisKit

struct AftercareInboxView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded([ClientAftercareInboxItem])
        case failed(String)
    }

    @State private var phase: Phase = .loading
    /// The booking a tapped row resolved to — drives the detail push.
    @State private var bookingNav: ClientBookingNav?
    /// The row (notification id) currently resolving its booking, for a spinner.
    @State private var resolving: String?
    @State private var resolveError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 60)
                case let .failed(message):
                    errorState(message)
                case let .loaded(items):
                    content(items)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Aftercare")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .navigationDestination(item: $bookingNav) { nav in
            BookingDetailView(booking: nav.booking, focusStep: "aftercare")
        }
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
        .onChange(of: session.refreshTick) { Task { await load() } }
        .alert("Couldn’t open that aftercare", isPresented: resolveErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please try again in a moment.")
        }
    }

    private var resolveErrorBinding: Binding<Bool> {
        Binding(get: { resolveError != nil }, set: { if !$0 { resolveError = nil } })
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ items: [ClientAftercareInboxItem]) -> some View {
        Text("Every aftercare summary you’ve received, all in one place.")
            .font(BrandFont.body(13))
            .foregroundStyle(BrandColor.textSecondary)

        if items.isEmpty {
            emptyState
        } else {
            VStack(spacing: 10) {
                ForEach(items) { item in
                    row(item)
                }
            }
        }
    }

    private var emptyState: some View {
        BrandSurface(tint: BrandColor.bgSecondary) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing yet")
                    .font(BrandFont.body(14, .bold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text("After your bookings, your pro will post aftercare here.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func row(_ item: ClientAftercareInboxItem) -> some View {
        let tappable = item.bookingId != nil
        Button {
            Task { await open(item) }
        } label: {
            BrandSurface(tint: BrandColor.bgSecondary) {
                cardBody(item)
            }
            .opacity(tappable ? 1 : 0.7)
        }
        .buttonStyle(.plain)
        .disabled(!tappable || resolving != nil)
    }

    private func cardBody(_ item: ClientAftercareInboxItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title)
                    .font(BrandFont.body(15, .bold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(2)
                if item.unread {
                    BrandPill(text: "NEW", tint: BrandColor.accent)
                }
                Spacer(minLength: 0)
                if resolving == item.id {
                    ProgressView().tint(BrandColor.accent).scaleEffect(0.8)
                }
            }

            if let scheduledFor = item.scheduledFor, !scheduledFor.isEmpty {
                Text("\(Wire.dateOnly(scheduledFor, timeZone: item.timeZone)) · \(item.timeZone)")
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
            }

            Text(item.proName)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(BrandColor.textSecondary)

            if let media = item.beforeAfter, media.hasAny {
                AftercareBeforeAfterPair(beforeUrl: media.beforeUrl, afterUrl: media.afterUrl)
            }

            Text(hintLabel(item.hint))
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textSecondary)

            if let body = item.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(body)
                    .font(BrandFont.body(12.5))
                    .foregroundStyle(BrandColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hintLabel(_ hint: ClientAftercareInboxItem.Hint) -> String {
        switch hint {
        case .recommendedWindow: return "Recommended booking window"
        case .recommendedDate: return "Recommended rebook date"
        case .notes: return "Aftercare notes"
        }
    }

    // MARK: - Actions

    private func open(_ item: ClientAftercareInboxItem) async {
        guard let bookingId = item.bookingId, resolving == nil else { return }
        resolving = item.id
        defer { resolving = nil }
        do {
            if let booking = try await session.client.bookings.booking(id: bookingId) {
                bookingNav = ClientBookingNav(booking: booking)
            } else {
                resolveError = "not found"
            }
        } catch {
            resolveError = "failed"
        }
    }

    private func load() async {
        do {
            let items = try await session.client.bookings.aftercareInbox()
            phase = .loaded(items)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn’t load your aftercare.")
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
}
