import Foundation

// How many session photos the app REQUIRES — and the words it uses to say so.
// One BEFORE, one AFTER. Everything past that is the pro's call.
//
// 🔴 Device feedback (2026-08-01, first live client session): the camera "made
// it mandatory to take multiple images." No gate anywhere actually counted past
// one — but the directed shoot's 4–5 step guide, its N-of-N progress dots, and a
// completion moment that only arrived at the LAST step made the whole set read
// as owed, and the same "at least one" rule was re-typed at four call sites in
// three different sentences. The rule lives HERE now, once: the guide directs,
// this type counts, and every gate + label asks it.

public enum ProSessionPhotoRequirement {
    /// Photos a phase must have before the session can move on. Extras are the
    /// pro's choice and are never counted against them.
    public static let requiredPerPhase = 1

    /// Whether a phase's captured count satisfies the requirement.
    public static func isMet(captured: Int) -> Bool { captured >= requiredPerPhase }

    /// How many photos the phase still owes (0 once the requirement is met).
    public static func outstanding(captured: Int) -> Int {
        max(0, requiredPerPhase - captured)
    }

    // MARK: - Copy
    //
    // The sentences live with the number so no screen can promise a different
    // one. Callers supply their own purpose ("to continue to service"), never
    // their own count.

    /// "before" / "after" / "session" — how a phase is said out loud.
    public static func phaseWord(_ phase: MediaPhase) -> String {
        switch phase {
        case .before: return "before"
        case .after: return "after"
        case .other: return "session"
        }
    }

    /// "1 before photo" — the requirement in words.
    public static func requiredNoun(_ phase: MediaPhase) -> String {
        "\(requiredPerPhase) \(phaseWord(phase)) photo\(requiredPerPhase == 1 ? "" : "s")"
    }

    /// "3 photos captured" / "1 photo captured". The count is pluralised rather
    /// than hard-coded plural — under a one-photo requirement, "1 photos
    /// captured" is the NORMAL case, not an edge one.
    public static func capturedSentence(_ count: Int) -> String {
        "\(count) photo\(count == 1 ? "" : "s") captured"
    }

    /// "Add 1 before photo to continue to service — extras are optional."
    public static func gateSentence(_ phase: MediaPhase, action: String, purpose: String) -> String {
        "\(action) \(requiredNoun(phase)) \(purpose) — extras are optional."
    }

    /// The camera's "you can stop now" moment, the instant the requirement is met.
    public static let metHeadline = "That’s the one you need"

    /// "Your before photo is saved. Keep shooting only if you want extras."
    public static func metDetail(_ phase: MediaPhase) -> String {
        "Your \(phaseWord(phase)) photo is saved. Keep shooting only if you want extras."
    }

    /// What leaving the camera empty-handed actually costs.
    public static func outstandingSentence(_ phase: MediaPhase) -> String {
        "This session still needs \(requiredNoun(phase))."
    }

    /// The camera's exit question when the requirement is still outstanding —
    /// a question, never a locked door.
    public static func leavingWithoutTitle(_ phase: MediaPhase) -> String {
        "Leave without a \(phaseWord(phase)) photo?"
    }

    /// The directed shoot, honestly labelled: a guide is a suggestion list, and
    /// only the requirement above is owed.
    public static func guideNote(_ phase: MediaPhase) -> String {
        "Only \(requiredNoun(phase)) is required — the rest of this set is optional."
    }
}
