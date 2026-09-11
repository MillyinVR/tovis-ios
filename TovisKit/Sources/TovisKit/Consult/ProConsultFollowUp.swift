import Foundation

// C2-4 — a professional asks the client one follow-up question from the Brief.
//
// The native twin of tovis-app `lib/dto/consult.ts` (ConsultProFollowUp*DTO),
// `lib/consult/proFollowUp.ts` (the parser whose rules `ProConsultFollowUpDraft`
// mirrors) and `lib/brand/consultProFollowUpCopy.ts` (the words).
//
// The CLIENT never sees this shape. Her side is the ordinary `FOLLOW_UP` thread
// card with `attribution` set ("From Susie"), answered through the ordinary
// follow-up route — the server files a `pro_` key on the pro's row instead of
// on a model round. That is what let build 78 answer a professional's question
// with no app change.

/// How urgent a professional's own follow-up question is. The two priorities
/// the September 9 product decision names, and nothing between.
public enum ProConsultFollowUpPriority: String, Codable, Sendable, Equatable {
    case needBeforeAppointment = "NEED_BEFORE_APPOINTMENT"
    case helpfulForPrep = "HELPFUL_FOR_PREP"
    /// A priority this build does not know. Rendered by its raw name rather
    /// than crashing the Brief; never offered when asking.
    case unknown

    /// The priorities a pro can pick when asking — never `.unknown`.
    public static let askable: [ProConsultFollowUpPriority] = [.needBeforeAppointment, .helpfulForPrep]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProConsultFollowUpPriority(rawValue: raw) ?? .unknown
    }
}

/// One question a PROFESSIONAL asked the client, as the pro reads it back: the
/// text the client sees, the priority the pro chose, and the client's one-tap
/// answer once it exists.
public struct ProConsultFollowUp: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    /// Server-minted, `pro_<n>`; the key the client's answer echoes back.
    public let questionKey: String
    public let priority: ProConsultFollowUpPriority
    /// What the client reads.
    public let text: String
    public let options: [ConsultInspirationQuestionOption]
    public let selectedValue: String?
    /// The chosen option's label, for display; nil while open.
    public let selectedLabel: String?
    /// The plan version current when it was asked; 0 when none existed.
    public let planVersion: Int
    public let askedAt: String
    public let answeredAt: String?

    /// Still waiting for the client. The open CAP counts these.
    public var isOpen: Bool { selectedValue == nil }
}

struct ProConsultFollowUpListResponse: Decodable, Sendable {
    let questions: [ProConsultFollowUp]
}

/// The server's limits, mirrored so the control can refuse before the round
/// trip. 🔴 The SERVER is the authority: these exist so the button can say why
/// it is dark, not so the app can skip the refusal.
public enum ProConsultFollowUpLimits {
    public static let maxOpen = 3
    public static let maxPerConsult = 12
    public static let maxTextLength = 300
    public static let maxLabelLength = 120
    public static let minOptions = 2
    public static let maxOptions = 6
}

/// The body `POST /pro/consults/{id}/follow-up` accepts. Built ONLY by
/// `ProConsultFollowUpDraft.normalized()`, so a body that exists is one the
/// parser's rules already passed.
public struct ProConsultFollowUpAsk: Encodable, Sendable, Equatable {
    public let priority: ProConsultFollowUpPriority
    public let text: String
    public let options: [String]
}

/// What the pro is typing. `normalized()` applies exactly the rules of
/// tovis-app `parseConsultProFollowUpAsk`: trim everything, refuse an empty or
/// over-long question, refuse fewer than two or more than six answers, refuse an
/// empty, over-long or duplicate (case-insensitive) answer.
public struct ProConsultFollowUpDraft: Sendable, Equatable {
    public var priority: ProConsultFollowUpPriority
    public var text: String
    public var options: [String]

    public init(
        priority: ProConsultFollowUpPriority = .helpfulForPrep,
        text: String = "",
        options: [String] = ["", ""]
    ) {
        self.priority = priority
        self.text = text
        self.options = options
    }

    /// The request the server would accept, or nil when it would refuse it.
    ///
    /// 🔴 Blank option rows are DROPPED, not refused: the form starts with two
    /// empty rows and may carry an unused third, and "two real answers plus an
    /// empty row" is a valid question. A NON-blank row that is too long, or a
    /// duplicate, still refuses the whole draft.
    public func normalized() -> ProConsultFollowUpAsk? {
        guard priority != .unknown else { return nil }
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count <= ProConsultFollowUpLimits.maxTextLength else { return nil }
        let labels = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard labels.count >= ProConsultFollowUpLimits.minOptions,
              labels.count <= ProConsultFollowUpLimits.maxOptions,
              labels.allSatisfy({ $0.count <= ProConsultFollowUpLimits.maxLabelLength }),
              Set(labels.map { $0.lowercased() }).count == labels.count
        else { return nil }
        return ProConsultFollowUpAsk(priority: priority, text: question, options: labels)
    }
}

/// The pro-facing words, mirroring tovis-app `lib/brand/consultProFollowUpCopy.ts`
/// line for line. Professional surfaces are not tenant-themed, so a plain enum
/// like `ConsultSuitabilityCopy`. Nothing here reaches a client.
public enum ProConsultFollowUpCopy {
    public static let title = "Ask a follow-up"
    public static let intro = "One quick question, answered with a tap. She sees your name on it, in the thread she already uses, and gets a gentle notification."
    public static let textLabel = "Your question"
    public static let textPlaceholder = "e.g. Have you had keratin or a smoothing treatment in the last year?"
    public static let textHint = "Up to 300 characters. Plain words — she may not know the technical term."
    public static let optionsLabel = "Answers she can tap"
    public static func optionPlaceholder(_ index: Int) -> String { "Option \(index + 1)" }
    public static let optionsHint = "Two to six short answers. Add “Not sure” when it is a real answer."
    public static let addOption = "Add an answer"
    public static let removeOption = "Remove"
    public static let priorityLabel = "How urgent"
    public static func priorityTitle(_ priority: ProConsultFollowUpPriority) -> String {
        switch priority {
        case .needBeforeAppointment: "Needed before the appointment"
        case .helpfulForPrep: "Helpful for prep"
        case .unknown: "Unspecified"
        }
    }
    public static func priorityHint(_ priority: ProConsultFollowUpPriority) -> String {
        switch priority {
        case .needBeforeAppointment: "The answer could change safety, timing, products, or whether the plan holds."
        case .helpfulForPrep: "Useful to know; nothing blocks on it."
        case .unknown: ""
        }
    }
    public static let submit = "Send question"
    public static let sending = "Sending…"
    public static let asked = "Sent"
    public static let waiting = "Waiting for her answer"
    public static let answered = "Answered"
    public static func openLimit(_ max: Int) -> String {
        "Up to \(max) questions can be open at once. Wait for an answer before asking another."
    }
    public static let totalLimit = "This consultation has reached its question limit."
    public static let failed = "Couldn’t send that. Try again."
    public static let invalid = "Add a question and at least two answers she can tap."
    public static let askedList = "Questions you’ve asked"
    public static let none = "You haven’t asked anything yet."
}
