import Foundation

// P5a — the consult THREAD, on the device.
//
// The native twin of tovis-app `lib/dto/consult.ts` (ConsultThread*DTO) and of
// the projection that builds it (`lib/consult/thread.ts`).
//
// One read — `GET /client/consult/{id}/thread` — replaces the five per-stage
// reads this flow used to make, and carries the id of the ONE message still
// waiting for the client. That field is what makes "reopening a consult resumes
// at the next open step" a server answer rather than a rule each client
// re-derives from four progress blockers and then disagrees about.
//
// 🔴 Nothing here is an authority over state. The stage endpoints are unchanged
// and remain the only way to ANSWER anything; a message is a rendering, and the
// thread is re-read after every mutation.

/// Who a message is from. `app` is the app's own voice — never the pro's.
public enum ConsultThreadAuthor: String, Decodable, Sendable, Equatable {
    case app = "APP"
    case client = "CLIENT"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConsultThreadAuthor(rawValue: raw) ?? .unknown
    }
}

/// Whether a message still awaits the client.
///
/// 🔴 SEVERAL may be `open` at once, and that is not a bug: the inspiration
/// review and the photo pack are genuinely concurrent server-side, so marking
/// one of them `blocked` would be a lie about what the server will accept.
/// Where to RESUME is `ConsultThread.nextOpenMessageId` — the FIRST open message
/// in thread order.
public enum ConsultThreadMessageState: String, Decodable, Sendable, Equatable {
    case done = "DONE"
    case open = "OPEN"
    case blocked = "BLOCKED"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConsultThreadMessageState(rawValue: raw) ?? .unknown
    }
}

/// Why the sticky Book the look button is not live.
public enum ConsultThreadBookGateReason: String, Decodable, Sendable, Equatable {
    case selfieRequired = "SELFIE_REQUIRED"
    case alreadyBooked = "ALREADY_BOOKED"
    case notLookAnchored = "NOT_LOOK_ANCHORED"
    case consultStopped = "CONSULT_STOPPED"
    case lookNotBookable = "LOOK_NOT_BOOKABLE"
    /// P7a-5 — this pro asks clients in this service category to finish the
    /// safety questions before a slot is held.
    ///
    /// 🔴 Unlike every other reason here, the client can CLEAR this one herself
    /// without leaving the thread, so the bar stays visible and disabled with
    /// `gateNote` under it. See `ConsultThreadBookBar.shouldShow`.
    case prepRequired = "PREP_REQUIRED"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConsultThreadBookGateReason(rawValue: raw) ?? .unknown
    }
}

/// The sticky CTA's state, decided by the SERVER so the two clients cannot
/// disagree about when the spark is bookable.
///
/// 🔴 It deliberately does not wait for the analysis. Booking runs the ORDINARY
/// look-booking path, which is why this carries the look's own service and media
/// rather than a consult proposal: the proposal path refuses with
/// ESTIMATE_MISSING until the analysis commits an estimate, and the analysis
/// takes about 100 seconds — longer than a spark lasts.
public struct ConsultThreadBookCta: Decodable, Sendable, Equatable, Identifiable {
    public let proposalConsultId: String?
    public let enabled: Bool
    public let reason: ConsultThreadBookGateReason?
    public let lookPostId: String?
    /// The look's linked service — what the ordinary booking path books.
    public let serviceId: String?
    /// The look's primary media, so the booking sheet's cover is her photo.
    public let lookMediaId: String?
    /// P7a-5 — the money line under the button: "From $180 · $25.00 deposit".
    ///
    /// 🔴 Composed by the SERVER and rendered verbatim. A percentage deposit
    /// arrives as a percentage, never as dollars — at the spark there is no
    /// location mode and no add-ons, so a dollar figure would be a guess shown
    /// as a promise. Never re-assemble or reformat it here.
    public let priceNote: String?
    /// P7a-5 — why the bar is dark when `reason == .prepRequired`, in the pro's
    /// own name. Server copy (it carries a `{pro}` slot), so it is rendered
    /// verbatim like every other filled bubble in this thread.
    public let gateNote: String?

    /// Identity for a presentation binding. The look is what is being booked, so
    /// it is the id — two taps on the same look must not reopen the sheet.
    public var id: String { lookPostId ?? "no-look" }
}

/// P7a-3 — one line of a plan diff, already in the client's language.
///
/// 🔴 `label`, `from` and `to` are SERVER copy, rendered verbatim. They come
/// from the brand's plan-diff table (tovis-app `lib/brand/…PlanDiffCopy.ts`) so
/// that this bubble and the pro's Brief say the same words about the same
/// change — which is the one thing a versioned Brief exists to guarantee. Never
/// re-word them here.
public struct ConsultPlanDiffEntry: Decodable, Sendable, Equatable, Identifiable {
    public let key: String
    public let label: String
    public let from: String?
    public let to: String?

    public var id: String { key }
}

/// One message. A single type with an optional payload per kind rather than an
/// enum with associated values: the wire is one JSON object shape, and a
/// `Decodable` enum over it would need a hand-written `init(from:)` that has to
/// be kept in step with every new kind by hand.
public struct ConsultThreadMessage: Decodable, Sendable, Identifiable {
    public enum Kind: String, Decodable, Sendable, Equatable {
        case text = "TEXT"
        case consent = "CONSENT"
        case question = "QUESTION"
        case inspiration = "INSPIRATION"
        case photoRequest = "PHOTO_REQUEST"
        case plan = "PLAN"
        /// P7a-3 — "your plan moved, and here is what changed". One per version
        /// after the first.
        case planUpdate = "PLAN_UPDATE"
        case booking = "BOOKING"
        /// P5g — one adaptive follow-up question, written for this client from
        /// everything read so far.
        case followUp = "FOLLOW_UP"
        /// A kind this build does not know. Rendered as nothing rather than as a
        /// crash — an older build must survive a server that learned a new
        /// message type, and silently skipping one message is the mildest
        /// possible failure.
        case unknown

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    public let kind: Kind
    public let id: String
    public let author: ConsultThreadAuthor
    public let state: ConsultThreadMessageState

    /// Present on TEXT, CONSENT, INSPIRATION, PLAN and BOOKING.
    public let text: String?

    // CONSENT
    public let requirements: [ConsultAgreementRequirement]?

    // QUESTION — the intake pack's question, and the versions answering it must
    // echo (answering POSTs a whole revision pinned to them).
    public let question: ConsultIntakeQuestion?
    public let answer: String?
    public let packVersion: Int?

    // INSPIRATION
    public let sourceDecisionRequired: Bool?
    public let source: ConsultInspirationSourceState?
    public let inspirationQuestion: ConsultInspirationQuestion?
    /// P5d — the CARD this message is, when it is one.
    ///
    /// Optional on the wire: a build that predates cards keeps rendering
    /// `inspirationQuestion` and simply shows no crop, which is the same thing
    /// it shows when a reference could not be read.
    public let card: ConsultInspirationCard?
    public let answeredQuestionCount: Int?
    public let specificDetailCount: Int?
    public let requiredSpecificDetailCount: Int?

    // PHOTO_REQUEST
    public let shot: ConsultCaptureShot?
    public let shotPackVersion: Int?
    public let slot: ConsultCaptureSlot?
    /// May this shot be taken RIGHT NOW? (P3b.)
    ///
    /// 🔴 NOT `state`, and reading `state` instead is the bug this replaced.
    /// `state == .blocked` means "not where resume lands" — a blocked photo
    /// request is deliberately still tappable, which is how she jumps between
    /// guided shots and how she retakes one after her plan exists. This asks
    /// the other question: would the SERVER accept the upload? The server
    /// derives it from the same predicates its write boundary uses, so a shot
    /// can never be offered here and refused there — which is exactly what
    /// happened on 2026-09-06, twice, on `eyes_closeup`.
    ///
    /// Optional: a server that predates the field means "yes", the behaviour
    /// every shipped build already had.
    public let shootable: Bool?

    // PLAN
    public let run: ConsultAnalysisRun?
    public let results: ConsultClientResults?
    public let awaitingStart: Bool?
    public let promptVersion: String?
    /// P7a-3 — which plan version `results` is; 0 while none exists.
    ///
    /// Optional on the wire like every field added since P5a: a build that
    /// predates versioning keeps rendering the plan card exactly as it did, and
    /// simply never says which version it is looking at.
    public let planVersion: Int?
    /// P7a-3 — an input changed after this version was built, so a new one is
    /// coming. The card's own copy already says so; this is for a client that
    /// wants to disable an action while it is true.
    public let updatePending: Bool?

    // PLAN_UPDATE
    /// The version this bubble announces (>= 2), and the one it is against.
    public let previousPlanVersion: Int?
    /// 🔴 EMPTY is a real value, not a missing one: a rerun that changed nothing
    /// still gets a bubble, with its own sentence. Hiding it would make the
    /// client's edit look ignored.
    public let changes: [ConsultPlanDiffEntry]?

    // BOOKING
    public let bookingId: String?

    // FOLLOW_UP (P5g)
    /// The question itself is in `text`. This is the key her answer echoes back;
    /// where that answer is FILED is the server's decision, not this client's.
    public let questionKey: String?
    public let followUpOptions: [ConsultInspirationQuestionOption]?
    public let selectedValues: [String]?
    /// 🔴 True when the model call failed and these are the intake pack's own
    /// remaining SAFETY questions instead. The server also sends its own bubble
    /// saying so; this is what lets a card mark itself.
    public let fallback: Bool?
    /// Which round of at most three this is.
    public let round: Int?

    /// Shared by QUESTION, INSPIRATION, PHOTO_REQUEST and PLAN — each names the
    /// schema its own mutation must echo.
    public let schemaVersion: Int?

    private enum CodingKeys: String, CodingKey {
        case kind, id, author, state, text
        case requirements
        case question, answer, packVersion
        case sourceDecisionRequired, source, card
        case answeredQuestionCount, specificDetailCount, requiredSpecificDetailCount
        case shot, shotPackVersion, slot, shootable
        case run, results, awaitingStart, promptVersion
        case planVersion, updatePending, previousPlanVersion, changes
        case bookingId
        case questionKey, fallback, round, selectedValues
        case followUpOptions = "options"
        case schemaVersion
    }

    /// Written by hand for ONE reason: the INTAKE question and the INSPIRATION
    /// question are both served under the key `question`, on different message
    /// kinds, and they are different types. A synthesized decoder cannot express
    /// that — two `CodingKeys` cases cannot share a raw value — and renaming the
    /// field on the wire would be a contract change to fix a client-side naming
    /// problem.
    ///
    /// Both are decoded with `try?` rather than branching on `kind`: a message
    /// whose kind this build does not know still decodes, and a question of the
    /// wrong shape lands as nil instead of failing the whole thread.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        id = try container.decode(String.self, forKey: .id)
        author = try container.decode(ConsultThreadAuthor.self, forKey: .author)
        state = try container.decode(ConsultThreadMessageState.self, forKey: .state)
        text = try container.decodeIfPresent(String.self, forKey: .text)

        requirements = try container.decodeIfPresent(
            [ConsultAgreementRequirement].self, forKey: .requirements
        )

        question = try? container.decodeIfPresent(
            ConsultIntakeQuestion.self, forKey: .question
        )
        inspirationQuestion = try? container.decodeIfPresent(
            ConsultInspirationQuestion.self, forKey: .question
        )
        answer = try container.decodeIfPresent(String.self, forKey: .answer)
        packVersion = try container.decodeIfPresent(Int.self, forKey: .packVersion)

        sourceDecisionRequired = try container.decodeIfPresent(
            Bool.self, forKey: .sourceDecisionRequired
        )
        source = try container.decodeIfPresent(
            ConsultInspirationSourceState.self, forKey: .source
        )
        // `try?` for the same reason the two questions above use it: a card of
        // a shape this build does not understand lands as nil rather than
        // failing the whole thread.
        card = try? container.decodeIfPresent(
            ConsultInspirationCard.self, forKey: .card
        )
        answeredQuestionCount = try container.decodeIfPresent(
            Int.self, forKey: .answeredQuestionCount
        )
        specificDetailCount = try container.decodeIfPresent(
            Int.self, forKey: .specificDetailCount
        )
        requiredSpecificDetailCount = try container.decodeIfPresent(
            Int.self, forKey: .requiredSpecificDetailCount
        )

        shot = try container.decodeIfPresent(ConsultCaptureShot.self, forKey: .shot)
        shotPackVersion = try container.decodeIfPresent(Int.self, forKey: .shotPackVersion)
        slot = try container.decodeIfPresent(ConsultCaptureSlot.self, forKey: .slot)
        shootable = try container.decodeIfPresent(Bool.self, forKey: .shootable)

        run = try container.decodeIfPresent(ConsultAnalysisRun.self, forKey: .run)
        results = try container.decodeIfPresent(ConsultClientResults.self, forKey: .results)
        awaitingStart = try container.decodeIfPresent(Bool.self, forKey: .awaitingStart)
        promptVersion = try container.decodeIfPresent(String.self, forKey: .promptVersion)
        planVersion = try container.decodeIfPresent(Int.self, forKey: .planVersion)
        updatePending = try container.decodeIfPresent(Bool.self, forKey: .updatePending)
        previousPlanVersion = try container.decodeIfPresent(
            Int.self, forKey: .previousPlanVersion
        )
        changes = try container.decodeIfPresent(
            [ConsultPlanDiffEntry].self, forKey: .changes
        )

        bookingId = try container.decodeIfPresent(String.self, forKey: .bookingId)

        questionKey = try container.decodeIfPresent(String.self, forKey: .questionKey)
        followUpOptions = try? container.decodeIfPresent(
            [ConsultInspirationQuestionOption].self, forKey: .followUpOptions
        )
        selectedValues = try container.decodeIfPresent(
            [String].self, forKey: .selectedValues
        )
        fallback = try container.decodeIfPresent(Bool.self, forKey: .fallback)
        round = try container.decodeIfPresent(Int.self, forKey: .round)

        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
    }
}

public struct ConsultThread: Decodable, Sendable {
    public let consultId: String
    public let status: ConsultSessionStatus
    public let professionalId: String
    /// The pro's public display name, honoring her `nameDisplay` preference.
    public let professionalDisplayName: String
    /// The FIRST message still awaiting the client, or nil when nothing is.
    /// Others may be open too; this is the one to land on.
    public let nextOpenMessageId: String?
    public let messages: [ConsultThreadMessage]
    /// Present only while the capture step is readable — the window in which the
    /// chart-copy choice can still be changed.
    public let chartCopy: ConsultChartCopyState?
    public let book: ConsultThreadBookCta
}

struct ConsultThreadResponse: Decodable, Sendable {
    let thread: ConsultThread
}
