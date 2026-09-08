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
    public static let profileDetailsTitle = "Your feature profile"
    public static let profileDetailsBody = "What the photos suggest about your features, so recommendations enhance what is already yours. Your professional confirms these in person — color readings from photos are approximate."
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
    public static let chartCopyTitle = "Keep these photos on my chart"
    public static let chartCopyBody =
        "Private to you and your professional, for future appointments. Turn it off any time before the analysis runs — otherwise photos are deleted after analysis either way."

    /// The offer to analyze a partial pack.
    public static func partialContinue(accepted: Int, total: Int) -> String {
        "Carry on with \(accepted) of \(total) photos"
    }

    public static let partialContinueBody =
        "You can keep going with the photos that came through. The views you skip can’t be analyzed, so those parts of your plan will honestly say unknown."

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
