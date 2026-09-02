// Step two of the booking flow — add-ons, on their own screen.
//
// Tori, 2026-08-14: *"the design says make it a moment and that's the goal."*
// It used to be a section inside the picker; it is now the same two-step the web
// flow has (`app/(main)/booking/add-ons/ui/AddOnsClient.tsx`), with the look, the
// pro, the time and the running hold carried across in a context strip so this
// reads as step two rather than a new screen.
//
// ⚠️ The hold arrives here BASE-SIZED. Every tick has to be pushed to the server
// before it can be booked (`PATCH /api/v1/holds/{id}`) — that is what makes the
// reserved window the window finalize will take (B1-A). A refusal un-ticks the
// add-on that caused it, so the client learns HERE, while it can still be
// dropped, rather than at the end of checkout.
import SwiftUI
import TovisKit

/// The look / pro / time carried over from the sheet.
struct BookingAddOnsContext: Equatable {
    let coverImageUrl: String?
    /// The stored original behind a rendered `coverImageUrl` — see `FallbackAsyncImage`.
    let coverFallbackImageUrl: String?
    let lookName: String?
    let serviceName: String
    let proName: String
    /// "Fri, Mar 6 · 2:15 PM", already resolved in the location's zone.
    let whenLabel: String

    /// "Lived-in blonde · Cleo Reyes" — the look and the pro, whichever survive.
    var title: String {
        [lookName ?? serviceName, proName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct BookingAddOnsView: View {
    @Environment(SessionModel.self) private var session

    let context: BookingAddOnsContext
    let holdId: String
    let holdExpiresAt: Date
    let offeringId: String
    let locationType: String
    let addOns: [BookingAddOn]
    /// The pro's no-show / late-cancel fee policy (M15). Non-nil only when the
    /// pro charges fees; when present the client must agree before booking, and
    /// the acceptance is sent to finalize.
    let cancellationPolicy: String?
    let openingId: String?
    /// Reports the booking AND the minutes of add-ons that went into it — the
    /// confirmation card states the width of the appointment that was actually
    /// booked, which the base service alone under-states.
    let onBooked: (FinalizedBooking, Int) -> Void

    /// What the client has ticked.
    @State private var selected: Set<String> = []
    /// What the HOLD actually reserves. It starts base-sized — every difference
    /// from `selected` is pushed to the server before the booking can complete.
    @State private var syncedIds: Set<String> = []
    @State private var syncing = false
    /// Bumped per sync so a stale response can't overwrite a newer toggle.
    @State private var syncSequence = 0
    @State private var didSeedPreselected = false

    @State private var submitting = false
    @State private var error: String?
    @State private var policyAccepted = false

    /// Grouped exactly as web groups them, by the add-on's own group name.
    private var groups: [(name: String, items: [BookingAddOn])] {
        var order: [String] = []
        var byGroup: [String: [BookingAddOn]] = [:]

        for addOn in addOns {
            let key = (addOn.group ?? "").trimmingCharacters(in: .whitespaces)
            let name = key.isEmpty ? "Add-ons" : key
            if byGroup[name] == nil { order.append(name) }
            byGroup[name, default: []].append(addOn)
        }

        return order.map { name in
            (name: name, items: (byGroup[name] ?? []).sorted { $0.sortOrder < $1.sortOrder })
        }
    }

    private var extraMinutes: Int {
        addOns.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.minutes }
    }

    private var extraPrice: Decimal {
        addOns
            .filter { selected.contains($0.id) }
            .reduce(Decimal(0)) { $0 + (Decimal(string: $1.price) ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    contextStrip

                    VStack(alignment: .leading, spacing: 6) {
                        Text("REVIEW & CUSTOMIZE")
                            .font(BrandFont.mono(10)).tracking(1.4)
                            .foregroundStyle(BrandColor.textMuted)
                        Text("Add-ons")
                            .font(BrandFont.display(26, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text("Optional upgrades that improve results + longevity.")
                            .font(BrandFont.body(12.5))
                            .foregroundStyle(BrandColor.textSecondary)
                    }

                    if let error {
                        BrandErrorBanner(message: error)
                    }

                    if addOns.isEmpty {
                        BrandSurface {
                            Text("No add-ons for this service right now. You’re good to go.")
                                .font(BrandFont.body(13, .semibold))
                                .foregroundStyle(BrandColor.textSecondary)
                        }
                    } else {
                        ForEach(groups, id: \.name) { group in
                            BrandSection(title: group.name) {
                                VStack(spacing: 10) {
                                    ForEach(group.items) { addOn in
                                        addOnRow(addOn)
                                    }
                                }
                            }
                        }

                        selectionSummary
                    }
                }
                .padding(20)
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle("Add-ons")
        .navigationBarTitleDisplayMode(.inline)
        // The picker hides its bar to draw the frame's ✕ over the cover; this
        // step needs the bar back for its way out.
        .toolbar(.visible, for: .navigationBar)
        .task { await seedPreselected() }
    }

    // MARK: - Context strip

    private var contextStrip: some View {
        HStack(spacing: 12) {
            if let raw = context.coverImageUrl, let url = URL(string: raw) {
                Color.clear
                    .frame(width: 38, height: 38)
                    .background(BrandColor.bgSecondary)
                    .overlay {
                        FallbackAsyncImage(
                            url: url,
                            fallbackURL: context.coverFallbackImageUrl.flatMap(URL.init(string:))
                        ) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(context.title)
                    .font(BrandFont.body(13, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                    .lineLimit(1)
                Text(context.whenLabel)
                    .font(BrandFont.body(11.5))
                    .foregroundStyle(BrandColor.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // The same hold that is running on the sheet, still running here.
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let remaining = Int(holdExpiresAt.timeIntervalSince(timeline.date).rounded(.down))
                Text(BookingSheetPresentation.holdStripLabel(secondsRemaining: remaining))
                    .font(BrandFont.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(
                        remaining <= 0 || BookingSheetPresentation.holdIsUrgent(secondsRemaining: remaining)
                            ? BrandColor.ember : BrandColor.gold
                    )
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(BrandColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Rows

    private func addOnRow(_ addOn: BookingAddOn) -> some View {
        let isSelected = selected.contains(addOn.id)
        return Button { toggle(addOn) } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(addOn.title)
                            .font(BrandFont.body(14, .semibold))
                            .foregroundStyle(isSelected ? BrandColor.onAccent : BrandColor.textPrimary)
                        if addOn.isRecommended {
                            // "Recommended" — the same word web uses. It used to
                            // read "Popular", which is a claim about other people
                            // rather than about this appointment.
                            Text("Recommended")
                                .font(BrandFont.body(10, .semibold))
                                .foregroundStyle(isSelected ? BrandColor.onAccent : BrandColor.accent)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(
                                    (isSelected ? BrandColor.onAccent : BrandColor.accent).opacity(0.15),
                                    in: Capsule()
                                )
                        }
                    }

                    // ⚠️ Prices are STARTING prices — "From $30", never a bare $30.
                    Text(addOnDetail(addOn))
                        .font(BrandFont.body(11.5))
                        .foregroundStyle(
                            isSelected ? BrandColor.onAccent.opacity(0.9) : BrandColor.textSecondary
                        )
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? BrandColor.onAccent : BrandColor.textMuted.opacity(0.6))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? BrandColor.accent : BrandColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? BrandColor.accent : BrandColor.textMuted.opacity(0.18),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(submitting)
    }

    private func addOnDetail(_ addOn: BookingAddOn) -> String {
        let price = BookingSheetPresentation.addOnPriceLabel(addOn.price)
        let minutes = addOn.minutes > 0 ? "+\(addOn.minutes) min" : nil
        return [minutes, price].compactMap { $0 }.joined(separator: " · ")
    }

    private var selectionSummary: some View {
        Group {
            if selected.isEmpty {
                Text("No add-ons selected")
            } else {
                Text(summaryLine)
            }
        }
        .font(BrandFont.body(12, .semibold))
        .foregroundStyle(BrandColor.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(BrandColor.textMuted.opacity(0.15), lineWidth: 1)
        )
    }

    private var summaryLine: String {
        var parts = ["Add-ons: \(selected.count)"]
        if extraMinutes > 0 { parts.append("Time +\(extraMinutes) min") }
        if let money = Wire.moneyDecimal(extraPrice), extraPrice > 0 {
            parts.append("Est. +\(money)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if let cancellationPolicy {
                Toggle(isOn: $policyAccepted) {
                    Text("\(cancellationPolicy) I agree to this cancellation policy.")
                        .font(BrandFont.body(12))
                        .foregroundStyle(BrandColor.textSecondary)
                }
                .tint(BrandColor.accent)
            }

            Button { Task { await completeBooking() } } label: {
                Group {
                    if submitting {
                        ProgressView().tint(BrandColor.onAccent)
                    } else {
                        Text(syncing ? "Updating your hold…" : "Complete booking")
                            .font(BrandFont.body(16, .semibold))
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .foregroundStyle(completeDisabled ? BrandColor.textMuted : BrandColor.onAccent)
                .background(completeDisabled ? BrandColor.textMuted.opacity(0.18) : BrandColor.accent)
                .clipShape(Capsule())
            }
            .disabled(completeDisabled)

            Text("No charge until the pro confirms.")
                .font(BrandFont.body(11)).foregroundStyle(BrandColor.textMuted)
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(BrandColor.bgPrimary)
        .overlay(alignment: .top) {
            Rectangle().fill(BrandColor.textMuted.opacity(0.15)).frame(height: 1)
        }
    }

    private var completeDisabled: Bool {
        submitting || syncing || (cancellationPolicy != nil && !policyAccepted)
    }

    // MARK: - Selection

    /// The set that arrives ticked.
    ///
    /// Keyed on `isPreselected` — the pro's own "starts ticked" opt-in — NOT on
    /// `isRecommended`, which only earns the badge two rows above (Tori,
    /// 2026-08-14). Web decides the initial selection the same way, in
    /// `booking/add-ons/page.tsx` and `AddOnsClient.tsx`; the two must agree or a
    /// pro who recommends an add-on without pre-selecting it gets the behaviour
    /// they asked for on web and the old behaviour here.
    ///
    /// Split out of `seedPreselected()` so it can be tested: the effect around it
    /// needs a live hold and a server, but WHICH FLAG decides the ticks is the
    /// part that was wrong, and it is pure.
    static func preselectedIds(from addOns: [BookingAddOn]) -> Set<String> {
        Set(addOns.filter(\.isPreselected).map(\.id))
    }

    /// Pre-selected add-ons arrive ticked, matching web.
    private func seedPreselected() async {
        guard !didSeedPreselected else { return }
        didSeedPreselected = true

        let preselected = Self.preselectedIds(from: addOns)
        guard !preselected.isEmpty else { return }

        selected = preselected
        await sync(preselected)
    }

    private func toggle(_ addOn: BookingAddOn) {
        guard !submitting else { return }
        var next = selected
        if next.contains(addOn.id) { next.remove(addOn.id) } else { next.insert(addOn.id) }
        selected = next
        Task { await sync(next) }
    }

    /// Re-size the hold to `ids` so the reservation covers what finalize will take.
    private func sync(_ ids: Set<String>) async {
        guard ids != syncedIds else { return }

        syncSequence += 1
        let sequence = syncSequence
        let added = ids.subtracting(syncedIds)
        syncing = true

        do {
            _ = try await session.client.booking.updateHoldAddOns(
                holdId: holdId, addOnIds: Array(ids).sorted()
            )
            guard sequence == syncSequence else { return }
            syncedIds = ids
            error = nil
        } catch {
            guard sequence == syncSequence else { return }
            self.error = describeSyncFailure(error, added: added)
            // Snap back to what the hold actually reserves — the refused add-on
            // was never held, so leaving it ticked would re-create the dead end.
            selected = syncedIds
        }

        if sequence == syncSequence { syncing = false }
    }

    /// The refusal a client should read.
    ///
    /// The server's reason is about the WINDOW ("that time is booked", "outside
    /// working hours"), which is confusing next to an add-on they just ticked —
    /// so name the add-on that pushed it over, and what to do about it. A refusal
    /// that says nothing about the window (a rate limit, a dropped connection) is
    /// passed through unchanged, because blaming the add-on would be a lie.
    private func describeSyncFailure(_ error: Error, added: Set<String>) -> String {
        guard let apiError = error as? APIError else {
            return "Couldn’t update your hold. Check your connection and try again."
        }

        let message = apiError.userMessage
        guard aboutTheWindow(apiError), !added.isEmpty else { return message }

        let titles = added.compactMap { id in addOns.first { $0.id == id }?.title }

        if titles.count == 1 {
            return "“\(titles[0])” doesn’t fit this appointment time — \(message) "
                + "Pick an earlier time, or book without it."
        }

        return "Those add-ons don’t fit this appointment time — \(message) "
            + "Pick an earlier time, or book without them."
    }

    /// A 429 is about the client's request rate, not about whether the widened
    /// appointment fits — same split web makes.
    private func aboutTheWindow(_ error: APIError) -> Bool {
        if case let .server(status, _, _) = error { return status != 429 }
        return false
    }

    // MARK: - Finalize

    private func completeBooking() async {
        guard !submitting else { return }

        if holdExpiresAt <= Date() {
            error = "That hold expired. Go back and pick another time."
            return
        }

        // Never book a selection the hold has not been widened to cover — that is
        // the exact gap B1-A closed.
        guard selected == syncedIds else {
            error = "Still updating your add-ons — one moment."
            return
        }

        submitting = true
        error = nil
        defer { submitting = false }

        do {
            let booked = try await session.client.booking.finalize(
                holdId: holdId, offeringId: offeringId, locationType: locationType,
                addOnIds: Array(selected).sorted(), openingId: openingId,
                cancellationPolicyAccepted: policyAccepted
            )
            onBooked(booked, extraMinutes)
        } catch let apiError as APIError {
            error = apiError.userMessage
        } catch {
            self.error = "Couldn’t complete the booking. Try again."
        }
    }
}
