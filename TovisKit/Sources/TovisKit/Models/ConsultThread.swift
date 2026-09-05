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
    public let enabled: Bool
    public let reason: ConsultThreadBookGateReason?
    public let lookPostId: String?
    /// The look's linked service — what the ordinary booking path books.
    public let serviceId: String?
    /// The look's primary media, so the booking sheet's cover is her photo.
    public let lookMediaId: String?

    /// Identity for a presentation binding. The look is what is being booked, so
    /// it is the id — two taps on the same look must not reopen the sheet.
    public var id: String { lookPostId ?? "no-look" }
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
        case booking = "BOOKING"
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
    public let answeredQuestionCount: Int?
    public let specificDetailCount: Int?
    public let requiredSpecificDetailCount: Int?

    // PHOTO_REQUEST
    public let shot: ConsultCaptureShot?
    public let shotPackVersion: Int?
    public let slot: ConsultCaptureSlot?

    // PLAN
    public let run: ConsultAnalysisRun?
    public let results: ConsultClientResults?
    public let awaitingStart: Bool?
    public let promptVersion: String?

    // BOOKING
    public let bookingId: String?

    /// Shared by QUESTION, INSPIRATION, PHOTO_REQUEST and PLAN — each names the
    /// schema its own mutation must echo.
    public let schemaVersion: Int?

    private enum CodingKeys: String, CodingKey {
        case kind, id, author, state, text
        case requirements
        case question, answer, packVersion
        case sourceDecisionRequired, source
        case answeredQuestionCount, specificDetailCount, requiredSpecificDetailCount
        case shot, shotPackVersion, slot
        case run, results, awaitingStart, promptVersion
        case bookingId
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

        run = try container.decodeIfPresent(ConsultAnalysisRun.self, forKey: .run)
        results = try container.decodeIfPresent(ConsultClientResults.self, forKey: .results)
        awaitingStart = try container.decodeIfPresent(Bool.self, forKey: .awaitingStart)
        promptVersion = try container.decodeIfPresent(String.self, forKey: .promptVersion)

        bookingId = try container.decodeIfPresent(String.self, forKey: .bookingId)
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
