import Foundation

// Book the Look, slice B8 — the CLIENT-facing booking proposal, on the device.
//
// The mirror of `ConsultBookingProposalDTO` (tovis-app `lib/dto/consult.ts`),
// and the whole reason the native flow can commit to a look at 3 AM without
// assembling anything itself.
//
// 🔴 EVERY FIGURE AND EVERY PROMISE HERE IS SERVER-COMPOSED. The price label,
// the estimate framing, the "your pro makes the final call" line, the per-line
// durations, the running total and the what-happens-when-you-tap sentence all
// arrive already rendered — the last of them routed through the same
// `getClientSubmittedBookingStatus` fork the commit runs, so a screen cannot
// promise something the booking then does not do. NOTHING in this file, and
// nothing that renders it, may add a price to a price or a minute to a minute.
// A tick re-asks the server; it never re-computes a total in Swift.

/// One line of the appointment, as the client is shown it.
///
/// A line carries NO rationale and NO source: the reasons are the pro's half of
/// decision 6, and what the client gets is the shape of her appointment — how
/// long it takes, and one number.
public struct ConsultBookingProposalLine: Decodable, Sendable {
    /// The pro's OWN menu name, answering "what is this appointment made of"
    /// after a consultation. Never a taxonomy the client picked from.
    public let serviceName: String
    /// Decimal string, like every other money field on this wire.
    public let price: String
    /// Rounded UP to the pro's slot granularity — never understates her day.
    public let durationMinutes: Int

    public init(serviceName: String, price: String, durationMinutes: Int) {
        self.serviceName = serviceName
        self.price = price
        self.durationMinutes = durationMinutes
    }
}

/// One enhancement the analysis recommends on top of the look (decision 10).
///
/// 🔴 THERE IS NO SERVICE NAME ON THIS TYPE, ON PURPOSE — the wire does not
/// carry one. Decision 10 gives the register ("a gloss keeps this tone from
/// going brassy"), never "add Toner Gloss", and decision 1 says a look never
/// names the service that produced it. Do not fetch a name from anywhere else
/// to put on the card.
public struct ConsultBookingProposalRecommendation: Decodable, Sendable, Identifiable, Equatable {
    /// The estimate line this offers, and the id the client's answer names — on
    /// the wire and in the query. Never a price and never a duration, so
    /// nothing the device can edit decides what she is charged.
    public let estimateLineId: String
    /// The ANALYSIS's own rationale, read from the revision the estimate pinned.
    /// Rendered verbatim; never re-written and never composed from a name.
    public let outcome: String
    /// Composed server-side, and nil when there is nothing to print — a
    /// complimentary enhancement has no price delta, an instant one has no
    /// duration delta. Never render "+$0".
    public let priceDeltaLabel: String?
    public let durationDeltaLabel: String?
    /// 🔴 The SERVER's answer for the ids that were sent, never a device-side
    /// guess and never seeded from anything else. Opt-in, never pre-checked.
    public let selected: Bool

    public var id: String { estimateLineId }

    public init(
        estimateLineId: String,
        outcome: String,
        priceDeltaLabel: String?,
        durationDeltaLabel: String?,
        selected: Bool
    ) {
        self.estimateLineId = estimateLineId
        self.outcome = outcome
        self.priceDeltaLabel = priceDeltaLabel
        self.durationDeltaLabel = durationDeltaLabel
        self.selected = selected
    }
}

public struct ConsultBookingProposal: Decodable, Sendable {
    public let consultId: String
    /// The mode this proposal was re-derived for. Echoed by the server, never
    /// assumed — and it is what the picker must be pinned to, so the sheet
    /// cannot re-ask a question this screen already answered.
    public let locationType: String
    /// The offering a hold and a finalize must be placed against — the floor.
    public let offeringId: String
    public let professionalId: String
    /// 🔴 A ROUTING KEY, NOT A LABEL. A look never names the service that
    /// produced it (B1) — nothing may render this.
    public let serviceId: String
    public let lookPostId: String
    /// Sum of the line durations, excluding buffer (as every booking width is).
    public let totalDurationMinutes: Int
    /// Sum of the line prices, as a decimal string.
    public let startingAtPrice: String
    /// The composed label, e.g. "Starting at $340" — rendered, never
    /// re-assembled. Nil when the total is not positive, which every surface
    /// renders as no price rather than "$0".
    public let startingAtLabel: String?
    /// Decision 5 travels WITH the price: this is an estimate from her photos
    /// and the pro makes the final call. Never render the number without these.
    public let estimateNote: String
    public let proDecidesNote: String
    /// What committing will actually do, decided by the pro's
    /// `autoAcceptBookings` toggle (decision 4).
    public let autoAccepts: Bool
    /// The rendered sentence for that outcome.
    public let commitNote: String
    public let lines: [ConsultBookingProposalLine]
    /// The enhancements the analysis recommends on top of the look (B7).
    /// `lines` above ALREADY reflects whatever she asked for, so the total is
    /// never the floor plus something rendered separately.
    ///
    /// Empty for a consult whose analysis recommended nothing beyond the look
    /// itself — rendered as no section rather than an empty one.
    public let recommendations: [ConsultBookingProposalRecommendation]

    /// The ids the server currently reports as chosen, in the SERVER's own
    /// order. What the next question and the finalize both send: a device that
    /// invented an order, or kept an id this proposal no longer offers, would
    /// let the review screen and the commit quietly disagree.
    public var selectedEnhancementLineIds: [String] {
        recommendations.filter(\.selected).map(\.estimateLineId)
    }

    public init(
        consultId: String,
        locationType: String,
        offeringId: String,
        professionalId: String,
        serviceId: String,
        lookPostId: String,
        totalDurationMinutes: Int,
        startingAtPrice: String,
        startingAtLabel: String?,
        estimateNote: String,
        proDecidesNote: String,
        autoAccepts: Bool,
        commitNote: String,
        lines: [ConsultBookingProposalLine],
        recommendations: [ConsultBookingProposalRecommendation]
    ) {
        self.consultId = consultId
        self.locationType = locationType
        self.offeringId = offeringId
        self.professionalId = professionalId
        self.serviceId = serviceId
        self.lookPostId = lookPostId
        self.totalDurationMinutes = totalDurationMinutes
        self.startingAtPrice = startingAtPrice
        self.startingAtLabel = startingAtLabel
        self.estimateNote = estimateNote
        self.proDecidesNote = proDecidesNote
        self.autoAccepts = autoAccepts
        self.commitNote = commitNote
        self.lines = lines
        self.recommendations = recommendations
    }
}

/// Why no proposal could be made. `safetyReviewRequired` is the load-bearing
/// one: the analysis routed to safety prerequisites, so the estimate's floor is
/// a service it explicitly declined to recommend yet, and no amount of the pro's
/// menu being well-configured makes that bookable unattended.
///
/// `unknown` is not a defensive nicety — the server may add a tenth code, and a
/// build that failed to decode it would turn an explained refusal into a crash
/// or a dead button. It renders the reason-agnostic message.
public enum ConsultBookingProposalRefusalCode: String, Decodable, Sendable, Equatable {
    case estimateMissing = "ESTIMATE_MISSING"
    case estimateRefused = "ESTIMATE_REFUSED"
    case safetyReviewRequired = "SAFETY_REVIEW_REQUIRED"
    case offeringOffMenu = "OFFERING_OFF_MENU"
    case modeNotOffered = "MODE_NOT_OFFERED"
    case modePriceUnset = "MODE_PRICE_UNSET"
    case modeDurationUnset = "MODE_DURATION_UNSET"
    case proSchedulingNotReady = "PRO_SCHEDULING_NOT_READY"
    case slotTooLong = "SLOT_TOO_LONG"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public struct ConsultBookingProposalAvailability: Decodable, Sendable {
    /// True exactly when `proposal` is non-nil.
    public let available: Bool
    public let reason: ConsultBookingProposalRefusalCode?
    public let proposal: ConsultBookingProposal?
    /// The consult's professional, present on REFUSALS as well as on answers —
    /// so every dead end has the same way out (message the pro, who already has
    /// the consultation brief) without the device assembling an id.
    public let professionalId: String

    public init(
        available: Bool,
        reason: ConsultBookingProposalRefusalCode?,
        proposal: ConsultBookingProposal?,
        professionalId: String
    ) {
        self.available = available
        self.reason = reason
        self.proposal = proposal
        self.professionalId = professionalId
    }
}

struct ConsultBookingProposalResponse: Decodable, Sendable {
    let proposal: ConsultBookingProposalAvailability
}
