// Pro Waitlist — the native counterpart of the web `/pro/waitlist` outreach
// workspace, backed by GET /api/v1/pro/waitlist (route already exists, so this is
// an iOS-only port — no backend change). Shows the clients waiting for this pro's
// services, grouped by service and FIFO-ranked (who has waited longest is rank #1).
// Two ways to fill a spot from each row — work the list top-down:
//   • Message   → resolve-or-create the WAITLIST thread and push ThreadView.
//   • Offer a time → propose a concrete in-salon slot (ProWaitlistOfferSheet →
//     POST /pro/waitlist/{entryId}/offer); the client confirms before it books.
// Reached from the pro profile's Business section.
import SwiftUI
import TovisKit

struct ProWaitlistView: View {
    @Environment(SessionModel.self) private var session

    private enum Phase {
        case loading
        case loaded(ProWaitlistOutreach)
        case failed(String)
    }

    @State private var phase: Phase = .loading

    // Message-a-client entry point: resolve-or-create the WAITLIST thread, then
    // push it into ThreadView. `messageWorkingId` is the entry currently resolving
    // (drives the per-row spinner + disable), shared across the whole list.
    @State private var messageNav: MessageThreadNav?
    @State private var messageWorkingId: String?

    // Offer-a-time entry point: present ProWaitlistOfferSheet for one entry (carries
    // the group's service so the sheet can resolve the offering). `confirmation` is a
    // brief "Offer sent to …" banner shown after a successful offer.
    @State private var offerTarget: OfferTarget?
    @State private var confirmation: String?
    /// Why the last "Message" tap failed, or nil. Shares the banner slot with
    /// `confirmation` and takes precedence over it.
    @State private var messageError: String?

    /// One waitlist entry queued for the offer sheet, plus its service context.
    private struct OfferTarget: Identifiable {
        let entry: ProWaitlistEntry
        let serviceId: String
        let serviceName: String
        var id: String { entry.waitlistEntryId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .loading:
                    HStack { Spacer(); ProgressView().tint(BrandColor.accent); Spacer() }
                        .padding(.top, 60)
                case let .failed(message):
                    errorState(message)
                case let .loaded(outreach):
                    content(outreach)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Waitlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(BrandColor.bgPrimary, for: .navigationBar)
        .refreshable { await load() }
        .task { if case .loading = phase { await load() } }
        .onChange(of: session.refreshTick) { Task { await load() } }
        .navigationDestination(item: $messageNav) { nav in
            ThreadView(thread: nav.thread)
        }
        .sheet(item: $offerTarget) { target in
            ProWaitlistOfferSheet(
                waitlistEntryId: target.entry.waitlistEntryId,
                clientName: target.entry.clientName,
                serviceId: target.serviceId,
                serviceName: target.serviceName
            ) { clientName in
                showConfirmation(clientName)
            }
        }
        .safeAreaInset(edge: .top) { confirmationBanner }
    }

    /// The top banner slot, shared by the success and failure cases so there is
    /// one banner rather than two stacked ones. Success: "Offer sent to …" after
    /// an offer — the row then reloads carrying its `pendingOffer`, so it swaps
    /// the offer action for an "Offered · <time>" badge. (It used to be the only
    /// feedback at all: sending an offer moves the entry to NOTIFIED, and the
    /// route listed ACTIVE entries only, so the client silently disappeared.)
    /// Failure: a refused "Message" tap, which the server answers with 409
    /// CLIENT_UNCLAIMED for a client who has never signed in.
    ///
    /// Whichever event happened last clears the other, so this ordering only
    /// breaks a tie that cannot occur.
    @ViewBuilder
    private var confirmationBanner: some View {
        if let messageError {
            banner(
                messageError,
                icon: "exclamationmark.circle.fill",
                tint: BrandColor.ember
            )
        } else if let confirmation {
            banner(
                confirmation,
                icon: "checkmark.circle.fill",
                tint: BrandColor.accent
            )
        }
    }

    private func banner(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(text)
                .font(BrandFont.body(13, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private func content(_ outreach: ProWaitlistOutreach) -> some View {
        if outreach.isEmpty {
            emptyState
        } else {
            Text("Clients waiting for your services, in the order they joined. Fill a spot from the top — offer a time or send a message.")
                .font(BrandFont.body(13))
                .foregroundStyle(BrandColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(outreach.services) { group in
                serviceGroup(group)
            }
        }
    }

    private func serviceGroup(_ group: ProWaitlistServiceGroup) -> some View {
        BrandSection(
            title: group.serviceName,
            trailing: "\(group.entries.count) waiting"
        ) {
            BrandSurface {
                VStack(spacing: 0) {
                    ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                        entryRow(entry, in: group)
                        if index < group.entries.count - 1 {
                            Divider().overlay(BrandColor.textMuted.opacity(0.12))
                        }
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: ProWaitlistEntry, in group: ProWaitlistServiceGroup) -> some View {
        HStack(spacing: 12) {
            Text("\(entry.rank)")
                .font(BrandFont.mono(11))
                .foregroundStyle(BrandColor.textSecondary)
                .frame(width: 26, height: 26)
                .background(BrandColor.bgSecondary)
                .clipShape(Circle())

            BrandAvatar(name: entry.clientName, avatarUrl: entry.avatarUrl, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.clientName)
                    .font(BrandFont.body(14, .bold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1)
                Text(subtitle(entry))
                    .font(BrandFont.body(12))
                    .foregroundStyle(BrandColor.textMuted)
                    .lineLimit(1)

                // Under the name, not beside it. As a trailing pill this line is
                // wide enough to squeeze the name column down to "Hett…" on a
                // phone — seen on device, not guessed. Web's outreach row puts it
                // in the same place.
                //
                // Two lines, because one truncated the TIME itself ("1:00…"),
                // which is the only part of this line worth reading.
                if let offer = entry.pendingOffer {
                    Text("Offered · \(Wire.dateTime(offer.startsAt, timeZone: nil)) · slot held")
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.accent)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            rowActions(entry, in: group)
        }
        .padding(.vertical, 10)
    }

    /// The two ways to fill a spot from a row: offer a concrete time (primary) or
    /// open a message thread (secondary). Stacked so both stay legible on a phone.
    ///
    /// A row that already has a live offer drops the offer action — the time is
    /// promised and (since F14) reserved, so the next move is to wait or message.
    /// The offer itself is shown under the client's name in `entryRow`.
    private func rowActions(_ entry: ProWaitlistEntry, in group: ProWaitlistServiceGroup) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if entry.pendingOffer == nil {
                Button {
                    offerTarget = OfferTarget(
                        entry: entry,
                        serviceId: group.serviceId,
                        serviceName: group.serviceName
                    )
                } label: {
                    Text("Offer a time")
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.onAccent)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 14)
                        .background(BrandColor.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                Task { await openThread(for: entry) }
            } label: {
                Group {
                    if messageWorkingId == entry.waitlistEntryId {
                        ProgressView().tint(BrandColor.accent)
                    } else {
                        Text("Message")
                    }
                }
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(BrandColor.textSecondary)
                .padding(.vertical, 7)
                .padding(.horizontal, 14)
                .overlay(
                    Capsule().stroke(BrandColor.textMuted.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(messageWorkingId != nil)
        }
    }

    /// "<preference> · joined <Mon D>" — the join date is resolved to the device
    /// zone at the edge (`Wire.monthDay`); the preference label is server-formatted.
    private func subtitle(_ entry: ProWaitlistEntry) -> String {
        let joined = Wire.monthDay(entry.joinedAt)
        return joined.isEmpty ? entry.preferenceLabel : "\(entry.preferenceLabel) · joined \(joined)"
    }

    private var emptyState: some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 8) {
                Text("No one on your waitlist yet")
                    .font(BrandFont.body(15, .bold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text("When a client joins your waitlist, they'll show up here in join order so you can offer them an opening.")
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
            let outreach = try await session.client.proSchedule.waitlistOutreach()
            phase = .loaded(outreach)
        } catch let error as APIError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn't load your waitlist just now. Please try again.")
        }
    }

    /// Show a brief "Offer sent to …" banner, auto-clearing after a few seconds.
    private func showConfirmation(_ clientName: String) {
        let name = clientName.isEmpty ? "the client" : clientName
        withAnimation {
            // The two share one slot, so retire the older event rather than let
            // a stale failure hide a fresh success.
            messageError = nil
            confirmation = "Offer sent to \(name). They’ll confirm before it books."
        }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation { confirmation = nil }
        }
    }

    /// Resolve-or-create this entry's thread and push the conversation. The
    /// failure is SURFACED, not swallowed: this used to be `try?` + `if let`,
    /// so a refusal — 409 CLIENT_UNCLAIMED against a client who has never
    /// signed in — left a button that spun and then did nothing at all.
    private func openThread(for entry: ProWaitlistEntry) async {
        guard messageWorkingId == nil else { return }
        messageWorkingId = entry.waitlistEntryId
        withAnimation {
            messageError = nil
            confirmation = nil
        }
        defer { messageWorkingId = nil }
        do {
            guard let thread = try await session.client.messages.openWaitlistThread(
                waitlistEntryId: entry.waitlistEntryId
            ) else {
                withAnimation { messageError = "Couldn’t open the conversation. Try again." }
                return
            }
            messageNav = MessageThreadNav(thread: thread)
        } catch let error as APIError {
            // The server's copy is already pro-facing, so pass it through.
            withAnimation { messageError = error.userMessage }
        } catch {
            withAnimation { messageError = "Couldn’t open the conversation. Try again." }
        }
    }
}
