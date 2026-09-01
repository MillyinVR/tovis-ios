// Book the Look, slice B8 — step two of the CONSULT path: review what the
// consultation put together, opt into the enhancements it recommends, and book.
//
// The native twin of web's `/booking/add-ons` acting as the proposal's REVIEW
// step. It sits where `BookingAddOnsView` sits on the ordinary path, and is a
// separate screen rather than a branch inside it for the reason the wire is
// separate too: an `OfferingAddOn` on top of a consult proposal is REFUSED by
// the server (B7 answered decision 10 with the estimate's own beyond-floor
// lines instead), so this screen has no add-on list, no hold re-sizing, and no
// device-side arithmetic at all.
//
// 🔴 THE SERVER IS THE ANSWER. A tick re-asks
// `GET /client/consult/{id}/proposal` for the new selection and replaces the
// WHOLE proposal — the lines, the length, the "Starting at" and each "+$40"
// all come back from the same function the finalize will run. Nothing here adds
// a price to a price; there is no arithmetic to disagree with the server's.
//
// 🔴 AND THE HOLD ALREADY COVERS EVERY ONE OF THEM. Availability and the
// reservation were sized for `'ALL'` — the widest thing this booking could
// become — because she opts in HERE, after the slot is reserved. So ticking
// fills space already held, the commit is always ≤ what was reserved, and there
// is no "that no longer fits" refusal at the end of checkout. Never try to
// re-size the hold from this selection.
import SwiftUI
import TovisKit

struct ConsultBookingReviewView: View {
    @Environment(SessionModel.self) private var session

    let context: BookingAddOnsContext
    let holdId: String
    let holdExpiresAt: Date
    /// The proposal as the picker was pinned to it — the floor alone, in the
    /// mode she chose. Every later answer replaces it wholesale.
    let initialProposal: ConsultBookingProposal
    /// The pro's no-show / late-cancel fee policy (M15). Non-nil only when the
    /// pro charges fees; the finalize REFUSES without the acceptance, so this
    /// gate applies to the consult path exactly as it does to the ordinary one.
    let cancellationPolicy: String?
    /// Reports the booking AND the width the appointment was actually booked
    /// at — the proposal's own total for the selection she committed to, which
    /// is the only honest number for the confirmation card.
    let onBooked: (FinalizedBooking, Int) -> Void

    @State private var proposal: ConsultBookingProposal
    /// Non-nil while a tick is being answered. The CTA is disabled until the
    /// server has answered for the CURRENT selection, so she can never commit
    /// to a screen that is one answer behind what she tapped.
    @State private var pendingSelection: [String]?
    @State private var submitting = false
    @State private var error: String?
    @State private var policyAccepted = false

    init(
        context: BookingAddOnsContext,
        holdId: String,
        holdExpiresAt: Date,
        initialProposal: ConsultBookingProposal,
        cancellationPolicy: String?,
        onBooked: @escaping (FinalizedBooking, Int) -> Void
    ) {
        self.context = context
        self.holdId = holdId
        self.holdExpiresAt = holdExpiresAt
        self.initialProposal = initialProposal
        self.cancellationPolicy = cancellationPolicy
        self.onBooked = onBooked
        _proposal = State(initialValue: initialProposal)
    }

    private var busy: Bool { submitting || pendingSelection != nil }

    private var completeDisabled: Bool {
        busy || (cancellationPolicy != nil && !policyAccepted)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ConsultReviewContextStrip(context: context, holdExpiresAt: holdExpiresAt)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(ConsultBookingCopy.reviewEyebrow)
                            .font(BrandFont.mono(10)).tracking(1.4)
                            .foregroundStyle(BrandColor.textMuted)
                        Text(ConsultBookingCopy.reviewTitle)
                            .font(BrandFont.display(26, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text(ConsultBookingCopy.proposalBody)
                            .font(BrandFont.body(12.5))
                            .foregroundStyle(BrandColor.textSecondary)
                    }

                    if let error { BrandErrorBanner(message: error) }

                    BrandSurface {
                        VStack(alignment: .leading, spacing: 12) {
                            ConsultProposalLines(proposal: proposal)

                            HStack(alignment: .firstTextBaseline) {
                                Text(ConsultBookingCopy.durationLabel)
                                    .font(BrandFont.body(13, .semibold))
                                    .foregroundStyle(BrandColor.textSecondary)
                                Spacer(minLength: 8)
                                Text(ConsultDurationLabel.text(proposal.totalDurationMinutes))
                                    .font(BrandFont.body(13, .semibold))
                                    .foregroundStyle(BrandColor.textPrimary)
                            }

                            ConsultStartingAtBlock(proposal: proposal)
                        }
                    }

                    enhancements
                }
                .padding(20)
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .navigationTitle(ConsultBookingCopy.reviewTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - The enhancement offer (decision 10)

    /// 🔴 Every card is phrased by OUTCOME. `outcome` is the analysis's own
    /// reason and the wire carries NO service name to fall back on, because a
    /// look never names the service that produced it. The two deltas are
    /// composed server-side and are nil when there is nothing to print, so a
    /// complimentary enhancement never reads "+$0".
    ///
    /// 🔴 Nothing starts ticked. `selected` is the SERVER's answer for the ids
    /// that were sent, so the only way a card is on is that she turned it on —
    /// which is what makes the total above a number she agreed to.
    @ViewBuilder
    private var enhancements: some View {
        if !proposal.recommendations.isEmpty {
            BrandSurface {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ConsultBookingCopy.enhancementsTitle)
                            .font(BrandFont.body(15, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text(ConsultBookingCopy.enhancementsBody)
                            .font(BrandFont.body(12))
                            .foregroundStyle(BrandColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(proposal.recommendations) { recommendation in
                        enhancementCard(recommendation)
                    }
                }
            }
        }
    }

    private func enhancementCard(
        _ recommendation: ConsultBookingProposalRecommendation
    ) -> some View {
        let active = recommendation.selected
        let deltas = [recommendation.durationDeltaLabel, recommendation.priceDeltaLabel]
            .compactMap { $0 }

        return Button {
            Task { await toggle(recommendation) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(recommendation.outcome)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !deltas.isEmpty {
                        Text(deltas.joined(separator: " · "))
                            .font(BrandFont.body(11, .semibold))
                            .foregroundStyle(active
                                ? BrandColor.onAccent.opacity(0.9)
                                : BrandColor.textSecondary)
                    }
                }

                Text(active
                     ? ConsultBookingCopy.enhancementAddedLabel
                     : ConsultBookingCopy.enhancementAddLabel)
                    .font(BrandFont.body(11, .semibold))
                    .foregroundStyle(active ? BrandColor.onAccent : BrandColor.textPrimary)
                    .padding(.vertical, 6).padding(.horizontal, 12)
                    .background(active
                                ? BrandColor.onAccent.opacity(0.16)
                                : BrandColor.bgPrimary)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(
                        active ? Color.clear : BrandColor.textMuted.opacity(0.2), lineWidth: 1))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? BrandColor.accent : BrandColor.bgPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(active ? 0 : 0.15), lineWidth: 1)
            )
            .opacity(busy ? 0.7 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .accessibilityIdentifier("consult-enhancement-\(recommendation.estimateLineId)")
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
                    if submitting { ProgressView().tint(BrandColor.onAccent) }
                    else {
                        Text(pendingSelection != nil
                             ? ConsultBookingCopy.enhancementsPendingLabel
                             : "Complete booking")
                            .font(BrandFont.body(16, .semibold))
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 15)
                .foregroundStyle(completeDisabled ? BrandColor.textMuted : BrandColor.onAccent)
                .background(completeDisabled ? BrandColor.textMuted.opacity(0.18) : BrandColor.accent)
                .clipShape(Capsule())
            }
            .disabled(completeDisabled)

            // 🔴 The server's own sentence for what this tap does, derived from
            // the same fork the commit runs — never a hardcoded promise. The
            // ordinary add-ons step's "No charge until the pro confirms" is a
            // lie to every client of an auto-accepting pro, which is exactly
            // why this one is composed server-side.
            Text(proposal.commitNote)
                .font(BrandFont.body(11))
                .foregroundStyle(BrandColor.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
        .background(BrandColor.bgPrimary)
    }

    // MARK: - Selection

    /// Re-ask the server for the new selection and replace the whole proposal.
    ///
    /// The ids are written back in the SERVER's own order, filtered to ones it
    /// actually offered: a selection carrying an id this proposal does not know
    /// would send the finalize something the derivation ignores, and the two
    /// screens would quietly disagree about what was booked.
    private func toggle(_ recommendation: ConsultBookingProposalRecommendation) async {
        guard !busy else { return }

        var next = Set(proposal.selectedEnhancementLineIds)
        if next.contains(recommendation.estimateLineId) {
            next.remove(recommendation.estimateLineId)
        } else {
            next.insert(recommendation.estimateLineId)
        }
        let ids = proposal.recommendations
            .map(\.estimateLineId)
            .filter { next.contains($0) }

        pendingSelection = ids
        error = nil
        defer { pendingSelection = nil }

        do {
            let answer = try await session.client.consult.proposal(
                consultId: proposal.consultId,
                locationType: proposal.locationType,
                enhancementLineIds: ids
            )
            // 🔴 A refusal here leaves the PREVIOUS proposal on screen rather
            // than clearing it: her held slot and the floor she already agreed
            // to are still bookable, and the honest answer is that this extra
            // could not be added — not that her booking evaporated.
            guard answer.available, let updated = answer.proposal else {
                error = ConsultBookingCopy.refusalMessage(answer.reason)
                return
            }
            proposal = updated
        } catch let apiError as APIError {
            error = apiError.userMessage
        } catch {
            self.error = "Couldn’t update your extras. Try again."
        }
    }

    // MARK: - Commit

    private func completeBooking() async {
        guard !completeDisabled else { return }
        submitting = true
        error = nil
        defer { submitting = false }

        do {
            let booked = try await session.client.booking.finalize(
                holdId: holdId,
                offeringId: proposal.offeringId,
                locationType: proposal.locationType,
                // 🔴 NEVER add-ons. An `OfferingAddOn` on top of a consult
                // proposal is refused on the wire.
                addOnIds: [],
                // The booking came from a look, so it carries the discovery
                // reference the finalize attributes it to.
                source: "DISCOVERY",
                cancellationPolicyAccepted: policyAccepted,
                lookPostId: proposal.lookPostId,
                consultId: proposal.consultId,
                consultEnhancementLineIds: proposal.selectedEnhancementLineIds
            )
            onBooked(booked, proposal.totalDurationMinutes)
        } catch let apiError as APIError {
            error = apiError.userMessage
        } catch {
            self.error = "Couldn’t complete the booking. Try again."
        }
    }
}

/// The look / pro / time / running hold carried over from the picker. Lifted
/// out of `BookingAddOnsView` verbatim rather than restated, so the two review
/// steps cannot drift into different strips.
struct ConsultReviewContextStrip: View {
    let context: BookingAddOnsContext
    let holdExpiresAt: Date

    var body: some View {
        HStack(spacing: 12) {
            if let raw = context.coverImageUrl, let url = URL(string: raw) {
                Color.clear
                    .frame(width: 38, height: 38)
                    .background(BrandColor.bgSecondary)
                    .overlay {
                        AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
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
}
