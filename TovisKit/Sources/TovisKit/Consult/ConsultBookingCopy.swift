import Foundation

/// Book the Look, B8 — the chrome around the proposal, on the device.
///
/// ⚠️ THE LOAD-BEARING SENTENCES ARE NOT HERE. The price label, the estimate
/// framing, the "your pro makes the final call" line, each enhancement's own
/// reason and the what-happens-when-you-tap sentence are all composed by the
/// SERVER and arrive on `ConsultBookingProposal` — the last of them routed
/// through the same fork the commit runs, so a screen cannot promise something
/// the booking then does not do. Everything below is chrome around them.
///
/// It mirrors tovis-app `lib/brand/defaultClientConsultBookingCopy.ts`. The
/// duplication is real and deliberate: the refusal wire carries a CODE, not a
/// sentence, so a native client that renders refusals has to hold its own
/// wording. Keep the two in step — if a refusal's meaning changes on the web,
/// it changes here.
///
/// A LOOK never names the service that produced it (B1), so nothing here labels
/// a service either. The proposal's own line names come from the pro's menu and
/// are her half of the answer — rendered as the shape of the appointment, never
/// as a taxonomy the client is choosing from.
public enum ConsultBookingCopy {
    public static let eyebrow = "BOOK THIS LOOK"
    public static let title = "Your appointment, from your consultation"
    public static let intro =
        "Choose how you want to be seen, then pick a time. The length below is what your professional will actually need for this look."

    public static let modeTitle = "How do you want to be seen?"
    public static let modeBody =
        "Prices and length differ between the two, so pick before you choose a time."
    public static let modeSalonLabel = "At the salon"
    public static let modeMobileLabel = "They come to you"
    /// 🔴 Reason-AGNOSTIC on purpose. The typed refusal can be any of nine
    /// things, and a hint that names one of them is wrong the other eight
    /// times. The hint says there IS an answer; selecting the mode gives it.
    public static let modeUnavailableLabel = "Tap to see why"
    public static let chooseModeFirst = "Pick salon or mobile to see times."

    public static let proposalTitle = "What you’d be booking"
    public static let proposalBody =
        "Put together from your photos and this professional’s own service list."
    public static let durationLabel = "Time set aside"
    public static let chooseTimeCta = "Choose a time"

    /// Every refusal is a rendered, explained state — never a dead end and
    /// never a silent disabled button. Each one says what happened and what
    /// happens next, and the way out of all of them is the same.
    public static let refusalTitle = "This look isn’t bookable here yet"
    public static let messageProCta = "Message your professional"

    public static func refusalMessage(
        _ reason: ConsultBookingProposalRefusalCode?
    ) -> String {
        switch reason {
        case .estimateMissing:
            return "We couldn’t put an appointment together from this consultation. Message your professional and she can book it for you."
        case .estimateRefused:
            return "This professional’s service list can’t express this look yet. Message her and she can put it together for you."
        case .safetyReviewRequired:
            return "Your analysis calls for a patch or strand test before this service. That has to happen with your professional first, so this one isn’t bookable on your own — she already has your consultation and can take it from here."
        case .offeringOffMenu:
            return "Part of this look is no longer on your professional’s service list. Message her and she can book it for you."
        case .modeNotOffered:
            return "Your professional doesn’t offer this look in that way. Try the other option."
        case .modePriceUnset:
            return "Your professional hasn’t set a price for this look in that way yet. Try the other option, or message her."
        case .modeDurationUnset:
            return "Your professional hasn’t set a length for this look in that way yet. Try the other option, or message her."
        case .proSchedulingNotReady:
            return "Your professional’s booking setup isn’t finished, so times can’t be offered yet. Message her and she can book it for you."
        case .slotTooLong:
            return "This look needs more time in one sitting than a single booking can hold. Your professional will split it across visits — message her to set it up."
        // A code this build does not know, and the no-reason refusal, get the
        // same honest generic answer rather than an invented cause.
        case .unknown, .none:
            return "This look isn’t bookable on your own right now. Message your professional and she can book it for you."
        }
    }

    // Book the Look, B7 — the enhancement offer (decision 10). Phrased around
    // what each one DOES for her; the sentences themselves come from her own
    // analysis, and no service is ever named.
    //
    // 🔴 "Nothing is added unless you add it" is the promise the whole slice
    // rests on: a recommendation she did not choose is a price she did not
    // agree to, and B6's in-chair notice only means anything if the number it
    // measures against was hers.
    public static let enhancementsTitle = "Recommended for this look"
    public static let enhancementsBody =
        "Your analysis suggests these on top of the look itself. Nothing is added unless you add it, and your professional still makes the final call."
    public static let enhancementAddLabel = "Add"
    public static let enhancementAddedLabel = "Added"
    public static let enhancementsPendingLabel = "Updating your booking…"

    public static let reviewEyebrow = "FROM YOUR CONSULTATION"
    public static let reviewTitle = "Your look"

    /// The booking sheet's title for an unnamed look on THIS path. Never the
    /// service name: a LOOK never names the service that produced it (B1), and
    /// this is the one screen whose entire point is that she is booking an
    /// outcome rather than picking off a menu.
    public static let unnamedLookTitle = "Book this look"
}
