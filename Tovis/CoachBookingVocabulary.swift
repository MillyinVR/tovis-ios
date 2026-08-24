// The booking's own words, in the coach's mouth (camera plan P3).
//
// Tori, 2026-08-23: *"i dont feel like it actually knows what im doing or what
// im photographing … i feel like its just reading lines."* Two causes were
// verified. tovis-app #974 fixed the first — a look's brief was read in script
// order rather than bound to what the lens was actually seeing. This is the
// second: the coach's own WORDS. "Center your subject" is what a machine that
// has never been told anything says.
//
// It needs no service detector to fix. The camera is already handed the
// booking's service name, and the session hub already has the client on
// screen — so the coach can say "Center Maya" and "let the balayage fill the
// frame" using vocabulary the booking established hours ago.
//
// SAME CONTRACT AS `LookDirectionScript` (#974), deliberately: this only ever
// REPLACES the words of a correction the coach has already decided to give, on
// the same scheduler and the same per-category cooldown. It cannot make the
// coach speak more often, sooner, or about something else. It is applied in
// `CoachEngine.apply`, never in `ShotCoach` — so every pinned
// `CoachReadinessTests` assertion keeps reading exactly today's canonical text,
// and the offline tuning bench keeps measuring the same lines.
//
// ONE difference from a look line: the `CoachMoment` is KEPT. A look line is a
// bespoke sentence the model wrote, so #974 strips the moment and speaks it
// verbatim; this only swaps a noun, and flattening every personality pack's
// flourish to do that would be a bad trade. The consequence is a deliberate
// precedence: booking vocabulary reaches Calm Mentor (the default voice, which
// defers to canonical text everywhere), and a pro who has chosen a pack keeps
// their pack's line. Teaching the packs to name the client is follow-up work,
// not a silent side effect of this one.
//
// Every derivation below is written as a REFUSAL rule. A coach that says a
// client's name wrong, out loud, in front of that client is worse than one that
// says "your subject" — so anything that isn't plainly a spoken first name or a
// plainly readable service noun falls back to today's canonical line.
import Foundation

/// What this shoot is of, in the booking's vocabulary. `.empty` (practice, or a
/// booking whose names aren't safe to speak) makes every lookup miss, so callers
/// fall back to the canonical coaching lines without a separate "is this on" flag.
struct CoachBookingVocabulary: Equatable, Sendable {
    static let empty = CoachBookingVocabulary(clientName: nil, workNoun: nil)

    /// The client's first name, exactly as the coach will say it ("Maya"), or
    /// nil when the booking's name didn't survive `firstName(from:)`.
    let clientName: String?
    /// The booking's own words for the work, article included ("the balayage"),
    /// or nil when the service name didn't survive `workNoun(from:)`.
    let workNoun: String?

    private init(clientName: String?, workNoun: String?) {
        self.clientName = clientName
        self.workNoun = workNoun
    }

    /// Build from what the camera is handed at a session: the booking's base
    /// service name and the client's stored full name.
    init(serviceName: String?, clientFullName: String?) {
        self.clientName = Self.firstName(from: clientFullName)
        self.workNoun = Self.workNoun(from: serviceName)
    }

    var isEmpty: Bool { clientName == nil && workNoun == nil }

    // MARK: - The lines

    /// The booking-specific line for a correction the coach has already decided
    /// to give, or nil to leave today's canonical words exactly as they are.
    ///
    /// Only moments whose canonical text is vague about WHO or WHAT is in the
    /// frame are listed. Everything else — level, colour, focus, a busy
    /// backdrop — is about the room or the camera, not the subject, and naming
    /// the client there would be noise dressed as specificity.
    func line(replacing nudge: CoachNudge) -> String? {
        guard !isEmpty else { return nil }
        let ctx = nudge.phraseCtx ?? CoachPhraseContext()
        switch nudge.moment {
        // The one line about the WORK rather than the person — and the one the
        // pro sees most often (composition wins ~19/35 lines on the bench
        // corpus). "Fill the frame" with WHAT was exactly the gap.
        case .compositionTooFar:
            guard let workNoun else { return nil }
            // Phrased as the canonical sentence with the noun appended, not
            // as a rewrite of it. The rewrite was tried first — "Move in
            // closer — LET \(workNoun) FILL the frame" — and it wraps to THREE
            // lines on a 375pt phone at a service name this still accepts,
            // which the 56pt lane would eat. This form clears the same
            // measurement with four characters to spare. Measured, not
            // guessed: `CameraLaneLineFitTests`.
            return "Move in closer — fill the frame with \(workNoun)"

        // Vision-grounded: the coach says where it can SEE them, which is the
        // difference between reading a line and looking at the picture. The
        // side is a statement of position, never a "move left" instruction —
        // the move direction is the sign convention `LevelCoach` still has
        // flagged unverified, and this is deliberately not a second one.
        case .compositionRecenter:
            guard let clientName else { return nil }
            guard let side = ctx.direction else { return "Center \(clientName)" }
            return "Center \(clientName) — off to the \(side)"

        case .compositionTooLow:
            guard let clientName else { return nil }
            return "Raise the camera — \(clientName)’s too low"

        case .compositionFaceRequired:
            guard let clientName else { return nil }
            return "Frame \(clientName)’s face for this shot"

        case .compositionOffFrame:
            guard let clientName else { return nil }
            return "\(clientName)’s outside the feed crop — center them"

        case .poseClipped:
            guard let clientName else { return nil }
            return "\(clientName)’s getting clipped — pull back"

        case .lightingBacklit:
            guard let clientName else { return nil }
            return "Light’s behind \(clientName) — turn them to face the window"

        // ⚠️ These two moments carry TWO canonical lines each — a face variant
        // and a flat-lay/detail variant (`LightingCoach`, `onFace`). Naming the
        // client on the variant that is about a tray of nails would be the
        // confidently-wrong advice the north star rules out, so the person
        // lines are gated on the flag the coach sets when it measured a face.
        case .lightingTooDark:
            guard let clientName, ctx.namesAPerson else { return nil }
            return "\(clientName)’s face is too dark — turn them toward the light"

        case .lightingBlownOut:
            guard let clientName, ctx.namesAPerson else { return nil }
            return "\(clientName)’s face is blown out — turn away from the bright light"

        default:
            return nil
        }
    }

    /// The nudge with its words in the booking's vocabulary. The category, the
    /// moment and the phrase context all survive — only `message` can change.
    func applied(to nudge: CoachNudge) -> CoachNudge {
        guard let line = line(replacing: nudge) else { return nudge }
        return CoachNudge(category: nudge.category, message: line,
                          moment: nudge.moment, phraseCtx: nudge.phraseCtx)
    }

    /// The same substitution for a dimensions-drawer row, through the SAME
    /// `line(replacing:)` — the drawer must never disagree with the lane about
    /// what the coach just said.
    func applied(to status: CoachStatus) -> CoachStatus {
        guard let message = status.message,
              let line = line(replacing: CoachNudge(
                  category: status.category, message: message,
                  moment: status.moment, phraseCtx: status.phraseCtx))
        else { return status }
        return CoachStatus(category: status.category, score: status.score,
                           message: line, why: status.why,
                           moment: status.moment, phraseCtx: status.phraseCtx)
    }

    // MARK: - Deriving the words

    /// Titles the coach must not read out as a first name.
    private static let honorifics: Set<String> = ["mr", "mrs", "ms", "miss", "mx", "dr", "prof"]

    /// A name long enough to be a name and short enough for the lane, spelled
    /// with letters. Anything else — an empty profile, an initial, a phone
    /// number a pro typed into the name field, a 30-character legal name —
    /// returns nil and the coach keeps saying "your subject".
    static func firstName(from fullName: String?) -> String? {
        guard let raw = fullName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        var words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > 1,
           honorifics.contains(words[0].lowercased().trimmingCharacters(in: .init(charactersIn: "."))) {
            words.removeFirst()
        }
        let candidate = (words.first ?? "").trimmingCharacters(in: .init(charactersIn: ".,;:"))
        // A bare title is not a name — "Center Dr" is worse than "Center your
        // subject", which is the whole test every rule in here has to pass.
        guard !honorifics.contains(candidate.lowercased()) else { return nil }
        guard candidate.count >= 2, candidate.count <= 14,
              candidate.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" || $0 == "’" })
        else { return nil }
        // A pro who typed "maya lopez" in lower case meant the name, not the
        // spelling — but "McKenzie" and "MAYA" are spelled the way they're
        // spelled, so only an all-lowercase word is touched.
        guard candidate.allSatisfy({ !$0.isUppercase }) else { return candidate }
        return candidate.prefix(1).uppercased() + candidate.dropFirst()
    }

    /// The joiners that turn a service name into a booking rather than a noun.
    private static let joiners = CharacterSet(charactersIn: "+&/,()·–—")

    /// The longest work noun the lane can carry. Measured, not guessed:
    /// `CameraLaneLineFitTests.theLongestLineTheVocabularyCanBuildStillFitsTheLane`
    /// lays the built sentence out in the real font at the real floor size
    /// against the real lane width, on the narrowest phone the app supports.
    static let maxWorkNounLength = 22

    /// The booking's own words for what's being photographed, article included.
    /// Nil whenever the stored service name isn't a noun the coach can read out
    /// mid-sentence — in which case the canonical "fill the frame" stands.
    static func workNoun(from serviceName: String?) -> String? {
        guard let raw = serviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        // An add-on list is a booking, not a thing in the frame: "Balayage +
        // Toner" is two line items, and the balayage is what the lens sees.
        var words = raw.components(separatedBy: joiners)
            .first?
            .split(whereSeparator: \.isWhitespace)
            .map(String.init) ?? []
        // A digit means the name is carrying a duration or a size ("60 min
        // blowout", "Full Set 2"), not a word for what's in the picture.
        // Checked BEFORE the tail trim below, or trimming the "2" off "Full
        // Set 2" would quietly turn a size marker into a noun.
        guard !words.contains(where: { $0.contains(where: \.isNumber) }) else { return nil }
        // "Silk Press w/ Trim" loses its "w" to the cut above; a one-letter
        // tail is always debris, never a word.
        while let last = words.last, last.count < 2 { words.removeLast() }
        let head = words.joined(separator: " ")
        guard !head.isEmpty, head.count <= maxWorkNounLength,
              head.first?.isLetter == true
        else { return nil }
        // Service names are stored Title Case and read as ordinary nouns
        // mid-sentence. Words that aren't plain Title/lower case — an acronym,
        // a brand — are left exactly as the pro spelled them.
        let spoken = words.map { word -> String in
            let isTitleCase = word.first?.isUppercase == true
                && word.dropFirst().allSatisfy { !$0.isUppercase }
            // A pro who typed the whole service in caps was formatting a menu,
            // not shouting — but an acronym ("IPL", "PMU") is spelled that way,
            // so only a word too long to be one is brought back down.
            let isShouted = word.count > 3 && word.allSatisfy { !$0.isLowercase }
            return isTitleCase || isShouted ? word.lowercased() : word
        }.joined(separator: " ")
        return spoken.lowercased().hasPrefix("the ") ? spoken : "the \(spoken)"
    }
}
