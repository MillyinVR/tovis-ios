// Book the Look, slice B8 — the client's booking door on a look-anchored
// consult, native. The mirror of web's
// `app/client/(gated)/consult/[id]/book/ClientConsultBooking.tsx`.
//
// 🔴 EVERY NUMBER AND EVERY PROMISE ON THIS SCREEN IS SERVER-COMPOSED. The
// price label, the estimate framing, the "your professional makes the final
// call" line, the line items, the total duration and the what-happens-when-you-
// tap sentence all arrive on `ConsultBookingProposal`; the last of those is
// routed through the same fork the commit runs. Nothing here re-derives a
// price, a duration, a mode's availability or an acceptance mode.
//
// A LOOK never names the service that produced it (B1). The line names below
// are the pro's OWN menu answering "what is this appointment made of" AFTER a
// consultation — the pro's half of decision 6 arriving in the client's hands as
// the shape of her booking, not a taxonomy she picked from.
import SwiftUI
import TovisKit

struct ConsultBookingView: View {
    @Environment(SessionModel.self) private var session

    let consultId: String
    /// The look's primary media, when the caller has it — the booking sheet's
    /// cover comes from it, so the sheet is visibly about the thing she tapped.
    var lookMediaId: String? = nil

    private enum Phase {
        case loading
        /// Both modes answered. Either may be a refusal; at least one always
        /// carries `professionalId`, which is the way out of every dead end.
        case answered(salon: ConsultBookingProposalAvailability,
                      mobile: ConsultBookingProposalAvailability)
        case failed(String)
    }

    @State private var phase: Phase = .loading
    /// 🔴 DELIBERATELY NO DEFAULT. The server refuses to guess a mode, and so
    /// does this screen: a salon price handed to someone who meant mobile is
    /// exactly what the mode reconciliation exists to prevent.
    @State private var mode: String?
    @State private var launch: ConsultBookLaunch?
    @State private var resolvingLaunch = false
    @State private var launchError: String?
    @State private var messageNav: MessageThreadNav?
    @State private var messageWorking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                switch phase {
                case .loading:
                    loadingCard
                case let .failed(message):
                    BrandErrorBanner(message: message)
                case let .answered(salon, mobile):
                    modeSection(salon: salon, mobile: mobile)
                    if let answer = selectedAnswer(salon: salon, mobile: mobile) {
                        if let proposal = answer.proposal, answer.available {
                            proposalSection(proposal)
                        } else {
                            refusalSection(answer)
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrandColor.bgPrimary.ignoresSafeArea())
        // 🔴 No navigation title. The eyebrow directly beneath the bar already
        // says "Book this look" — found by looking at the screen, where the two
        // read as a stutter. The on-screen header is the heading; the bar
        // carries only the way back out.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .navigationDestination(item: $messageNav) { nav in
            ThreadView(thread: nav.thread)
        }
        .sheet(item: $launch) { launch in
            BookingFlowView(
                professionalId: launch.proposal.professionalId,
                proName: launch.proName,
                offering: launch.offering,
                locationType: launch.proposal.locationType,
                lookMediaId: lookMediaId,
                consultProposal: launch.proposal
            )
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ConsultBookingCopy.eyebrow)
                .font(BrandFont.mono(10)).tracking(1.3)
                .foregroundStyle(BrandColor.accent)
            Text(ConsultBookingCopy.title)
                .font(BrandFont.display(26, .semibold))
                .foregroundStyle(BrandColor.textPrimary)
            Text(ConsultBookingCopy.intro)
                .font(BrandFont.body(14))
                .foregroundStyle(BrandColor.textSecondary)
        }
    }

    private var loadingCard: some View {
        BrandSurface {
            HStack(spacing: 10) {
                ProgressView().tint(BrandColor.accent)
                Text("Putting your appointment together…")
                    .font(BrandFont.body(14))
                    .foregroundStyle(BrandColor.textSecondary)
            }
        }
    }

    // MARK: - Mode

    private func modeSection(
        salon: ConsultBookingProposalAvailability,
        mobile: ConsultBookingProposalAvailability
    ) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ConsultBookingCopy.modeTitle)
                        .font(BrandFont.body(16, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                    Text(ConsultBookingCopy.modeBody)
                        .font(BrandFont.body(13))
                        .foregroundStyle(BrandColor.textSecondary)
                }

                modeButton("SALON", label: ConsultBookingCopy.modeSalonLabel,
                           available: salon.available)
                modeButton("MOBILE", label: ConsultBookingCopy.modeMobileLabel,
                           available: mobile.available)

                if mode == nil {
                    Text(ConsultBookingCopy.chooseModeFirst)
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                }
            }
        }
    }

    private func modeButton(_ value: String, label: String, available: Bool) -> some View {
        let selected = mode == value
        return Button {
            // Changing the mode drops any resolved launch: the sheet is pinned
            // to ONE proposal, and re-opening it against the other mode's would
            // show times for a proposal she has never seen.
            mode = value
            launch = nil
            launchError = nil
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(BrandFont.body(14, .semibold))
                        .foregroundStyle(selected ? BrandColor.onAccent : BrandColor.textPrimary)
                    // An unavailable mode stays TAPPABLE on purpose: selecting
                    // it renders the typed reason it can't be booked, which is
                    // the explained state the quality bar asks for. A greyed-out
                    // button explains nothing.
                    if !available {
                        Text(ConsultBookingCopy.modeUnavailableLabel)
                            .font(BrandFont.body(11, .semibold))
                            .foregroundStyle(selected
                                ? BrandColor.onAccent.opacity(0.85)
                                : BrandColor.textMuted)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 12).padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? BrandColor.accent : BrandColor.bgPrimary)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(BrandColor.textMuted.opacity(selected ? 0 : 0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("consult-proposal-mode-\(value)")
    }

    // MARK: - Refusal

    private func refusalSection(_ answer: ConsultBookingProposalAvailability) -> some View {
        BrandSurface {
            VStack(alignment: .leading, spacing: 12) {
                Text(ConsultBookingCopy.refusalTitle)
                    .font(BrandFont.body(16, .semibold))
                    .foregroundStyle(BrandColor.textPrimary)
                Text(ConsultBookingCopy.refusalMessage(answer.reason))
                    .font(BrandFont.body(13.5))
                    .foregroundStyle(BrandColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await openMessageThread(answer.professionalId) }
                } label: {
                    HStack(spacing: 8) {
                        if messageWorking { ProgressView().tint(BrandColor.textPrimary) }
                        Text(ConsultBookingCopy.messageProCta)
                            .font(BrandFont.body(13, .semibold))
                    }
                    .foregroundStyle(BrandColor.textPrimary)
                    .padding(.vertical, 10).padding(.horizontal, 16)
                    .background(BrandColor.bgPrimary)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(BrandColor.textMuted.opacity(0.22), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(messageWorking)
            }
        }
        .accessibilityIdentifier("consult-proposal-refusal")
    }

    // MARK: - The proposal

    private func proposalSection(_ proposal: ConsultBookingProposal) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            BrandSurface {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ConsultBookingCopy.proposalTitle)
                            .font(BrandFont.body(16, .semibold))
                            .foregroundStyle(BrandColor.textPrimary)
                        Text(ConsultBookingCopy.proposalBody)
                            .font(BrandFont.body(13))
                            .foregroundStyle(BrandColor.textSecondary)
                    }

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

                    // Decision 4's client-facing half, composed by the server
                    // through the same fork the commit runs.
                    Text(proposal.commitNote)
                        .font(BrandFont.body(13.5, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let launchError {
                BrandErrorBanner(message: launchError)
            }

            Button {
                Task { await openPicker(proposal) }
            } label: {
                Group {
                    if resolvingLaunch { ProgressView().tint(BrandColor.onAccent) }
                    else {
                        Text(ConsultBookingCopy.chooseTimeCta)
                            .font(BrandFont.body(16, .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(BrandColor.onAccent)
                .background(BrandColor.accent)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(resolvingLaunch)
            .accessibilityIdentifier("consult-proposal-choose-time")
        }
    }

    // MARK: - Loading

    private func selectedAnswer(
        salon: ConsultBookingProposalAvailability,
        mobile: ConsultBookingProposalAvailability
    ) -> ConsultBookingProposalAvailability? {
        switch mode {
        case "SALON": return salon
        case "MOBILE": return mobile
        default: return nil
        }
    }

    /// Both modes are asked up front, exactly as the web page's server
    /// component asks for both: the mode buttons have to know which of them can
    /// be booked BEFORE she picks, and neither answer reserves anything.
    ///
    /// 🔴 Asked with NO enhancements. The floor alone is the default everywhere
    /// she has not chosen (decision 10, opt-in never pre-checked); the
    /// enhancement offer lives on the review step, after the slot is held.
    private func load() async {
        guard case .loading = phase else { return }
        do {
            async let salon = session.client.consult.proposal(
                consultId: consultId, locationType: "SALON", enhancementLineIds: [])
            async let mobile = session.client.consult.proposal(
                consultId: consultId, locationType: "MOBILE", enhancementLineIds: [])
            phase = .answered(salon: try await salon, mobile: try await mobile)
        } catch let apiError as APIError {
            phase = .failed(apiError.userMessage)
        } catch {
            phase = .failed("Couldn’t load your appointment. Pull to try again.")
        }
    }

    /// Resolve the floor OFFERING the picker needs, then open it pinned to this
    /// proposal. The offering is a routing key here — the sheet renders the
    /// look, never the service name (B1).
    private func openPicker(_ proposal: ConsultBookingProposal) async {
        guard !resolvingLaunch else { return }
        resolvingLaunch = true
        launchError = nil
        defer { resolvingLaunch = false }

        guard let resolved = await LookBooking.offering(
            client: session.client,
            professionalId: proposal.professionalId,
            offeringId: proposal.offeringId
        ) else {
            // 🔴 Refuse rather than fall back to some other offering: the hold
            // and the finalize are both placed against the FLOOR, and a picker
            // opened on a different offering would reserve the wrong thing.
            launchError = "Couldn’t open times for this look right now. Try again in a moment."
            return
        }

        launch = ConsultBookLaunch(
            proposal: proposal,
            proName: resolved.proName,
            offering: resolved.offering
        )
    }

    private func openMessageThread(_ professionalId: String) async {
        guard !messageWorking else { return }
        messageWorking = true
        defer { messageWorking = false }
        // Best-effort, exactly as the profile's Message button is: leaving her
        // on this screen is better than an error about a thread.
        if let thread = try? await session.client.messages
            .openProfileThread(professionalId: professionalId) {
            messageNav = MessageThreadNav(thread: thread)
        }
    }
}

private struct ConsultBookLaunch: Identifiable {
    let proposal: ConsultBookingProposal
    let proName: String
    let offering: ProOffering
    var id: String { proposal.consultId + proposal.locationType }
}

// MARK: - Shared pieces (this screen and the review step render the same rows)

/// The lines of the appointment. ONE implementation, used by the proposal
/// screen and by the review step, because the two render the same rows and
/// would otherwise grow two answers to "what is this made of".
struct ConsultProposalLines: View {
    let proposal: ConsultBookingProposal

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Array(proposal.lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(line.serviceName)
                        .font(BrandFont.body(13, .semibold))
                        .foregroundStyle(BrandColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text("\(ConsultDurationLabel.text(line.durationMinutes)) · \(ConsultMoney.text(line.price))")
                        .font(BrandFont.body(12, .semibold))
                        .foregroundStyle(BrandColor.textMuted)
                        .layoutPriority(1)
                }
                .padding(.vertical, 10).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BrandColor.bgPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

/// Decision 5, rendered: THE NUMBER NEVER STANDS ON ITS OWN. `startingAtLabel`
/// is composed server-side and is nil when the total is not positive, which
/// every surface renders as no price rather than "$0" — so the framing lines
/// stay even then, because "we can't quote this" still needs "your professional
/// makes the final call" beside it.
struct ConsultStartingAtBlock: View {
    let proposal: ConsultBookingProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label = proposal.startingAtLabel {
                Text(label)
                    .font(BrandFont.display(22, .bold))
                    .foregroundStyle(BrandColor.textPrimary)
            }
            Text("\(proposal.estimateNote) \(proposal.proDecidesNote)")
                .font(BrandFont.body(12, .semibold))
                .foregroundStyle(BrandColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrandColor.bgPrimary)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// "1 hr 45 min" — the native twin of web's `formatDurationLabel`. Kept beside
/// the screens that use it rather than re-spelled inline at each one.
enum ConsultDurationLabel {
    static func text(_ minutes: Int) -> String {
        guard minutes > 0 else { return "—" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        if rest == 0 { return hours == 1 ? "1 hr" : "\(hours) hrs" }
        return "\(hours) hr \(rest) min"
    }
}

/// A wire decimal string as money. The wire sends "340.00"; this renders "$340"
/// the way web's `formatRoundedDollars` does, and falls back to the raw figure
/// rather than dropping a price it cannot parse.
enum ConsultMoney {
    static func text(_ price: String) -> String {
        guard let value = Decimal(string: price) else { return "$\(price)" }
        let rounded = NSDecimalNumber(decimal: value).doubleValue.rounded()
        return "$\(Int(rounded))"
    }
}
