import Foundation

/// P5a — the consult thread's chrome, on the device.
///
/// ⚠️ THE SPOKEN BUBBLES ARE NOT HERE. Every sentence the app says in the thread
/// is composed by the SERVER and arrives already filled on
/// `ConsultThreadMessage.text` — one file, `tovis-app
/// lib/brand/defaultClientConsultThreadCopy.ts`, so the voice can be edited
/// without shipping either client. What lives below is the chrome the DEVICE
/// composes: button labels, and the sentences under a CTA that is not live yet.
///
/// It mirrors the `bookCta*` half of that same brand file. The duplication is
/// deliberate and small: the gate arrives as a CODE, not a sentence, so a native
/// client that explains refusals has to hold its own wording. Keep the two in
/// step — if a gate's meaning changes on the web, it changes here.
///
/// Voice rules, same as the server's half: warm, short, no jargon before its
/// picture, never a question that sounds like a test, and never impersonating
/// the professional — she is who the Brief is being prepared FOR.
public enum ConsultThreadCopy {
    public static let ownWordsLabel = "Say it in your own words"
    public static let ownWordsPlaceholder = "Tell me what you mean, or correct what I noticed…"
    public static let ownWordsLimit = "Please keep your response to 600 characters."
    /// The INTAKE and FOLLOW-UP box. Different words from the inspiration one:
    /// there she is correcting what the model noticed about a picture, here she
    /// is answering a question whose options ran out (Tori, 2026-09-13).
    public static let intakeOwnWordsPlaceholder =
        "Add anything that matters, or answer here if none of these fits…"
    /// Files what she typed as the answer ITSELF, with no option chosen.
    public static let intakeOwnWordsSend = "None of these — use what I wrote"
    public static let profileDetailsTitle = "What your photos show"
    public static let profileDetailsBody = "These details help explain the style ideas below. Photos can change how colors look. Your professional will check these details with you in person."
    public static let styleOptionsTitle = "Style options to discuss"
    public static let styleOptionsBody = "Your preferences come first. These photo-based suggestions are optional starting points to discuss with your professional."
    public static let styleReasonLabel = "Why this could work for you"

    public static let screenTitle = "Your consult"

    public static let bookCtaLabel = "Book the look"
    public static let bookCtaSelfieRequired =
        "Send one photo of yourself and this opens up."
    public static let bookCtaNotBookable =
        "This look isn’t bookable on its own — message your professional and she can set it up."

    /// Shown while the one read is in flight.
    public static let loading = "Loading your consult…"

    /// The chart-copy control, which is a standing preference rather than a step.
    public static let chartCopyTitle = "Save these photos in my appointment record"
    public static let chartCopyBody =
        "Save a copy for you and your professional to use at future visits. You can turn this off before your plan is built. The temporary photos used to build the plan are deleted either way."

    // MARK: - The daylight break (Tori, 2026-09-12)
    //
    // A clean stop at the first daylight photo: build now, or add the photos
    // first. Both answers are hers, and both say the same thing — the photos
    // are wanted, and they can wait. Copy says WHY daylight: it shows her
    // truest colour, where indoor light warms or flattens it.
    //
    // 🔴 These REPLACE the partial-pack offer ("Carry on with N of M photos"),
    // deleted here as it was on the web. That control asked her to weigh a
    // fraction she had no way to judge, and only appeared once some photos were
    // already in; the honest question is asked before the first one.
    //
    // Mirrors `tovis-app lib/brand/defaultClientConsultThreadCopy.ts`.

    public static let captureChoice =
        "I can build your look now from what you’ve given me, or you can add the daylight photos first. Either way I’d love them — daylight shows your truest colour, and that makes the plan a lot sharper. You can add or change them any time before your appointment."
    public static let captureChoiceBuildNow = "Build my look now"
    public static let captureChoiceAddPhotos = "Add daylight photos first"
    /// The standing way out, under the thread, once she chose the photos.
    public static let captureChoiceLater =
        "You can build your look whenever you like and add the rest later. Anything a missing photo would have shown just comes back as unknown — no guessing."
    /// What the app says back once she has built without a photo.
    public static let captureChoiceBuilt =
        "No problem. Add your daylight photos whenever you like, any time before your appointment, and I’ll look at your plan again with them."
    /// The one-line way to send a photo her plan was built without.
    public static let captureAddLater = "Add this photo"

    /// Rule 8, on the plan card: say what the photographs could not settle.
    ///
    /// 🔴 Shown only when MOST of the accepted frames carried a colour warning
    /// (`mostFramesWarm`, decided on the server). One warm frame among five is
    /// not a caveat about the reading, it is noise — and a caveat shown every
    /// time stops being read.
    ///
    /// Mirrors `tovis-app lib/brand/defaultClientConsultResultsCopy.ts`.
    public static func warmLightCaveat(warm: Int, total: Int) -> String {
        "\(warm) of your \(total) photos were taken in warm indoor light, so the colour readings below are less certain than the rest. Your professional will check them in daylight."
    }

    /// The UNKNOWNs, said out loud (Tori, 2026-09-13). Her photo bought her
    /// something — say that first — and then say plainly what is still missing
    /// and which picture would settle it. A standing invitation, never a demand.
    public static let daylightGapTitle = "What daylight photos would add"
    public static func daylightGapProvisional(count: Int) -> String {
        "Your first photo gave me \(count) of these readings already — they’re a starting point, not a final answer."
    }
    public static func daylightGapBody(list: String) -> String {
        "A few daylight photos would settle the rest: \(list). You can add them any time before your appointment, and I’ll look at your plan again with them."
    }
    /// One clause per unlock code. 🔴 Returns nil for a code this build has not
    /// been taught, and the caller DROPS it: a server that learns a new group
    /// must not put a placeholder in the middle of her sentence.
    public static func daylightGapUnlock(_ code: String) -> String? {
        switch code {
        case "HAIR_LEVELS": "how light or dark your hair actually is"
        case "HAIR_TONE_AND_CONDITION": "your hair’s shade, texture and condition"
        case "SKIN_TONE_AND_SEASON": "your skin tone and the colours that suit it"
        case "EYE_AND_BROW_DETAIL": "your eye and brow shape"
        default: nil
        }
    }

    /// The look plan's two provisional lines, which must NOT share a sentence
    /// (Tori, 2026-09-13). A reading can be thin for two quite different
    /// reasons, and only one of them is something she can act on.
    ///
    /// 🔴 Mirrors `tovis-app lib/brand/consultClientPlanCopy.ts`. The plan card
    /// is composed on the DEVICE from the served plan, so these sentences live
    /// here the way the `bookCta*` refusals do — keep the two in step.

    /// Something she can still answer is outstanding.
    public static let planDraft = "Draft — a few details still need confirming"
    /// The plan she CAN book, built off an early selfie. Says what it was built
    /// from, that she may go ahead, and what daylight would add.
    public static let planFromEarlyPhotos =
        "Built from the photos you’ve added so far — you can book this now. Add daylight photos any time before your appointment and I’ll look at your plan again with them."

    /// The plan card's own controls.
    public static let planStart = "Build my plan"
    public static let planStarting = "Starting…"
    public static let planSeeAll = "See the whole plan"

    /// The inspiration source decision.
    public static let inspirationAddPhoto = "Add a photo"
    public static let inspirationSkip = "Carry on without one"

    /// The button under a question card's options.
    public static let questionNext = "Next"

    /// Consent.
    public static let consentAgreed = "Agreed"
    public static func consentAccept(_ kind: ConsultAgreementKind) -> String {
        kind == .adult18PlusAttestation ? "I confirm I’m 18 or older" : "I consent"
    }
}
