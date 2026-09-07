import Foundation

/// P7a-4 — "does this booking's prep still owe the pro something?", as the
/// server decided it.
///
/// The Sept 5 flow moved the consult's safety questions from before the BOOKING
/// to before the CHAIR, which only works if the pro can see, at a glance, that
/// they are still outstanding. This is that glance: the same badge web's
/// `deriveConsultPrepBadge` composes, printed verbatim.
///
/// 🔴 Nothing here is a gate. An unanswered safety question is a reason for the
/// pro to reach out — "a looked-after moment, not a gate" — so this is a pill
/// beside the status, never a block on the appointment.
///
/// Shaped exactly like `ProClientConfirmation`, deliberately: the pro's rows
/// already speak one badge language (kind / label / description / tone /
/// significant), and a fourth badge with its own shape would be a fourth thing
/// to reason about on one card.
public struct ConsultPrepBadge: Decodable, Sendable, Equatable {
    /// Every state web's helper can emit today (its `CONSULT_PREP_BADGE_STATES`
    /// union). A value outside this set is a FUTURE state this build does not
    /// know — `display` hides it rather than printing a claim about a client's
    /// safety answers that it cannot vouch for.
    public enum State: String, Sendable, CaseIterable {
        case noConsult = "NO_CONSULT"
        case complete = "COMPLETE"
        case incomplete = "INCOMPLETE"
        case overdue = "OVERDUE"
    }

    /// DERIVED from `State`, never hand-listed beside it.
    public static let knownKinds: Set<String> = Set(State.allCases.map(\.rawValue))

    public let kind: String?
    /// The short words a pill prints ("Prep incomplete", "Prep overdue").
    public let label: String?
    /// Plain-words expansion, and the accessibility label — a tone read aloud
    /// is nothing.
    public let description: String?
    /// Web Badge tone vocabulary, mapped by the one `wireBadgeTone` table.
    public let tone: String?
    /// false for NO_CONSULT — a booking with nothing to prepare renders
    /// NOTHING. Web omits the whole field in that case (most bookings), so this
    /// is belt-and-braces; the decision lives in the web helper.
    public let significant: Bool?

    private enum CodingKeys: String, CodingKey {
        case kind, label, description, tone, significant
    }

    public init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container?.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        label = (try? container?.decodeIfPresent(String.self, forKey: .label)) ?? nil
        description = (try? container?.decodeIfPresent(String.self, forKey: .description)) ?? nil
        tone = (try? container?.decodeIfPresent(String.self, forKey: .tone)) ?? nil
        significant = (try? container?.decodeIfPresent(Bool.self, forKey: .significant)) ?? nil
    }

    public init(kind: String?, label: String?, description: String?, tone: String?, significant: Bool?) {
        self.kind = kind
        self.label = label
        self.description = description
        self.tone = tone
        self.significant = significant
    }

    /// The state a surface may render, or nil to show nothing: the kind must be
    /// one this build knows and the wire label must be non-blank (the words are
    /// server-composed and never rebuilt on device, so without them there is
    /// nothing truthful to print).
    ///
    /// `description` falls back to the label rather than to empty — it is the
    /// accessibility string, the one place this must not go silent.
    public var display: Display? {
        guard let kind, let state = State(rawValue: kind) else { return nil }
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let spelled = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let readable = spelled.map { $0.isEmpty ? trimmed : $0 } ?? trimmed
        return Display(
            state: state,
            label: trimmed,
            description: readable,
            tone: tone ?? "neutral",
            significant: significant ?? true
        )
    }

    /// A validated, renderable state — non-optional fields only.
    public struct Display: Sendable, Equatable {
        public let state: State
        public let label: String
        public let description: String
        public let tone: String
        public let significant: Bool

        public var kind: String { state.rawValue }
    }
}
