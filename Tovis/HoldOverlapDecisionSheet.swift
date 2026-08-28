import SwiftUI
import TovisKit

/// "Someone is checking out for this time" — the choice a pro is given before
/// booking over a client's live reservation (B5 follow-up, Tori 2026-08-28).
///
/// 🔴 THIS SHEET RENDERS NO CLIENT IDENTITY, and cannot: its only input about
/// the held client is `decision.relationship`, a three-case enum. There is no
/// name, initial, avatar or contact detail to render because the server never
/// sends one — a client mid-checkout has not agreed to be identified to a pro
/// before they commit (B5), and new-or-returning is the single exception Tori
/// approved. Adding anything else here is a product decision.
///
/// A sheet rather than an `.alert` (which is what the override prompt uses): an
/// alert's message is a static string, and the whole point of this one is a
/// number that moves. The countdown is `BookingSheetPresentation
/// .holdCountdownLabel` — the SAME formatter the client's own checkout and the
/// pro's calendar tile use, driven by a `TimelineView` exactly as the tile is
/// (`ProCalendarTimeGrid`), so one reservation cannot read three ways.
struct HoldOverlapDecisionSheet: View {
    let decision: HeldSlotDecision
    let intent: HoldOverlapPromptIntent
    /// The booking location's zone — the slot is shown in the pro's own day.
    let timeZone: String?
    let busy: Bool
    let onProceed: () -> Void
    let onWait: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("◆ CHECKOUT IN PROGRESS")
                    .font(BrandFont.mono(10))
                    .foregroundStyle(BrandColor.ember)
                Text(HoldOverlapPromptCopy.title)
                    .font(BrandFont.display(22, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
            }

            // One sentence, in the order the pro reads it: WHO (new or
            // returning to them), WHAT, WHEN. The relationship label is the
            // only thing said about the person.
            Text(HoldOverlapPromptCopy.summary(decision, timeZone: timeZone))
                .font(BrandFont.body(15))
                .foregroundStyle(BrandColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("holdOverlapSummary")

            countdownRow

            if let note = HoldOverlapPromptCopy.additionalHeldSlotsNote(
                decision.additionalHeldSlots)
            {
                Text(note)
                    .font(BrandFont.body(13))
                    .foregroundStyle(BrandColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(HoldOverlapPromptCopy.anonymityNote)
                .font(BrandFont.body(12))
                .foregroundStyle(BrandColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button(action: onProceed) {
                    Text(HoldOverlapPromptCopy.proceedLabel(intent))
                        .font(BrandFont.body(16, .semibold))
                        .foregroundStyle(BrandColor.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(BrandColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(busy)
                .accessibilityIdentifier("holdOverlapProceed")

                // "Wait" is the safe answer, so it is the one a tired thumb
                // finds: full width, bottom of the stack, and what a swipe-down
                // dismissal means too.
                Button(action: onWait) {
                    Text(HoldOverlapPromptCopy.waitLabel)
                        .font(BrandFont.body(15, .semibold))
                        .foregroundStyle(BrandColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .disabled(busy)
                .accessibilityIdentifier("holdOverlapWait")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        .presentationDetents([.medium])
        // 🔴 The two buttons are the ONLY exits. A swipe-down would set the
        // binding to nil without running either handler, leaving the calendar's
        // optimistic tile sitting on minutes nothing was written for — and, on
        // the create screen, an idempotency key nobody released. A decision
        // sheet should be answered, not dismissed.
        .interactiveDismissDisabled()
        .accessibilityIdentifier("holdOverlapDecision")
    }

    /// The live clock. A `TimelineView` rather than a stored countdown for the
    /// same reason the calendar tile uses one: the value is a function of the
    /// wall clock, and nothing is pushed at expiry — a hold dies by the clock.
    @ViewBuilder
    private var countdownRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = Int(
                decision.expiresAt.timeIntervalSince(context.date).rounded(.down))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if remaining > 0 {
                    Text(
                        BookingSheetPresentation.holdCountdownLabel(
                            secondsRemaining: remaining)
                    )
                    .font(BrandFont.mono(24))
                    .foregroundStyle(
                        BookingSheetPresentation.holdIsUrgent(secondsRemaining: remaining)
                            ? BrandColor.ember : BrandColor.textPrimary
                    )
                    .accessibilityIdentifier("holdOverlapCountdown")

                    Text(HoldOverlapPromptCopy.countdownSuffix.uppercased())
                        .font(BrandFont.mono(11))
                        .foregroundStyle(BrandColor.textSecondary)
                } else {
                    // The pro is mid-decision. A sheet that emptied under their
                    // thumb would leave them wondering what they just tapped, so
                    // it says the minutes are free rather than going blank.
                    Text(HoldOverlapPromptCopy.countdownLapsedNote)
                        .font(BrandFont.body(14))
                        .foregroundStyle(BrandColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(BrandColor.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
