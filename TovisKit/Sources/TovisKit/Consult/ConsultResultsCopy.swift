import Foundation

/// The whole-plan screen's words.
///
/// ⚠️ Unlike the thread's bubbles, these are NOT served: the results screen is
/// composed on the device from the analysis payload, exactly as the web page is
/// composed from the same payload and its own brand copy. So this file is the
/// device's mirror of `tovis-app lib/brand/defaultClientConsultResultsCopy.ts`
/// — keep the two in step, word for word, the way `ConsultBookingCopy` and its
/// web twin are kept.
///
/// Voice rules, same as everywhere else in the consult: warm, short, no jargon
/// before its picture, never a promise, and every observation framed as
/// something the professional will check in person.
public enum ConsultResultsCopy {
    public static let title = "Directions to discuss with your professional"
    public static let eyebrow = "Your beauty consult"
    public static let intro =
        "These photo-based directions can help start the conversation. Your professional will assess your hair in person and decide what is achievable."

    public static let clientWordsTitle = "What you shared"

    public static let aiObservationsTitle = "What the photos suggest"
    public static let aiObservationsBody =
        "These observations are a starting point for your professional to verify in person."
    public static let baseLevelLabel = "Color near your scalp"
    public static let lightestLevelLabel = "Lightest color in your hair"
    public static let toneLabel = "Color shade"
    public static let conditionLabel = "Visible condition"
    public static let densityLabel = "How full your hair looks"
    public static let textureLabel = "How straight or curly your hair looks"
    public static let unknownLabel = "Couldn’t tell from the photos"

    public static let profileTitle = "What your photos show"
    public static let profileBody =
        "These details help explain the style ideas below. Photos can change how colors look. Your professional will check these details with you in person."

    public static let styleDirectionsTitle = "Style options to discuss"
    public static let styleDirectionsBody =
        "Your preferences come first. These photo-based suggestions are optional starting points to discuss with your professional."
    public static let whyItFlattersLabel = "Why this could work for you"

    /// 🔴 ALWAYS rendered, including when there is nothing in it. An empty
    /// safety section is a statement — "we found nothing specific, and your pro
    /// still has to check" — and hiding it would read as a clean bill of health
    /// nobody gave.
    public static let safetyTitle = "Safety and history to discuss"
    public static let safetyEmpty =
        "The photo review did not find a specific concern. Your professional still needs to check your hair and treatment history before starting."
    public static let safetyItemSuffix = "Discuss this with your professional before service."

    public static let achievabilityTitle = "What may be achievable"
    /// 🔴 UNKNOWN and REQUIRES_PRO_ASSESSMENT deliberately say the SAME thing.
    /// "Unknown" is not a state the client can do anything with; what it means
    /// for her is that a person has to look.
    public static func achievabilityLabel(_ assessment: String) -> String {
        switch assessment {
        case "LIKELY_SINGLE_APPOINTMENT": "May be possible in one appointment"
        case "LIKELY_MULTI_APPOINTMENT": "May take more than one appointment"
        default: "Needs an in-person professional assessment"
        }
    }

    public static let recommendationsTitle = "Directions to discuss"
    /// One recommendation is a valid result, not a short list (Tori,
    /// 2026-09-04) — so it gets a heading that reads as the pro's considered
    /// answer rather than a plural that came up one shy.
    public static let singleRecommendationTitle = "Your pro’s recommendation for this look"
    public static let recommendationDiscussionPrefix =
        "A direction to discuss with your professional:"

    public static let meCardEyebrow = "Me card · locked"
    public static let meCardTitle = "Your fuller analysis can live here later"
    public static let meCardBody =
        "The Me card is not available in this pilot. You can tell us this would interest you; this does not unlock anything or sign you up."
    public static let meCardTapLabel = "I’m interested"
    public static let meCardTappedLabel = "Interest recorded · still locked"

    /// The hair LEVEL tiles, as a COLOUR rather than a number.
    ///
    /// 🔴 "Level 5" is a colourist's word, and rule 2 of the voice is no jargon
    /// before its picture. The web renders the same reading through
    /// `defaultClientConsultInspirationCopy.cards.attributeShortNames` — the
    /// noun phrases below, which are its values verbatim.
    ///
    /// 🔴 Schema v4 sends two NAMED ends of the head. v3 sent one min/max pair
    /// and both clients rendered it "Level 4–5", which a colourist reads as
    /// base-to-lightest — from a field that never said that was what it meant.
    public static func hairLevel(_ value: String) -> String {
        switch value {
        case "LEVEL_1": "near-black"
        case "LEVEL_2": "very dark brown"
        case "LEVEL_3": "dark brown"
        case "LEVEL_4": "medium-dark brown"
        case "LEVEL_5": "medium brown"
        case "LEVEL_6": "light brown"
        case "LEVEL_7": "dark blonde"
        case "LEVEL_8": "medium blonde"
        case "LEVEL_9": "light blonde"
        case "LEVEL_10": "palest blonde"
        default: unknownLabel
        }
    }
}
