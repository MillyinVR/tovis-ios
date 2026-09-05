import Foundation

// C1-C7 wire contract for the booking-attached, hair-color-only AI consult.
// Raw capture bytes and private storage pointers deliberately do not appear in
// any durable model here. The only upload location the API returns is a
// short-lived signed URL, consumed inside ConsultService.

public enum ConsultSessionStatus: String, Decodable, Sendable {
    case consentRequired = "CONSENT_REQUIRED"
    case intakeReady = "INTAKE_READY"
    case intakeInProgress = "INTAKE_IN_PROGRESS"
    case mediaReady = "MEDIA_READY"
    case analysisPending = "ANALYSIS_PENDING"
    case analyzing = "ANALYZING"
    case completed = "COMPLETED"
    case consentRevoked = "CONSENT_REVOKED"
    case cancelled = "CANCELLED"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public struct ConsultSession: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: ConsultSessionStatus
    public let bookingId: String
    public let professionalId: String
    public let serviceCategoryId: String
    public let createdAt: String
}

struct ConsultSessionResponse: Decodable, Sendable {
    let consult: ConsultSession
}

/// GET /client/consult/availability — the server's answer to whether the
/// consult entry surface is open for a booking. The server owns the whole
/// decision (founder gate incl. the recorded eval deferral, booking
/// eligibility, session ownership); the device never re-derives any of it and
/// shows an entry point only on an explicit `available: true`.
public struct ConsultAvailability: Decodable, Sendable {
    public let available: Bool
    /// The caller's existing session for this booking, when one exists.
    public let consult: ConsultSession?

    public init(available: Bool, consult: ConsultSession?) {
        self.available = available
        self.consult = consult
    }
}

struct ConsultAvailabilityResponse: Decodable, Sendable {
    let availability: ConsultAvailability
}

// ── Book the Look, B2/B8 — the LOOK-anchored consult ───────────────────────
//
// A consult anchored to a LOOK and a professional, with NO booking. A
// DELIBERATELY SEPARATE type from `ConsultSession` rather than a nullable
// `bookingId` on it: shipped builds decode `ConsultSession.bookingId` as a
// non-optional String, and the booking-anchored endpoints they read must keep
// their exact shape. Everything downstream — agreements, intake, inspiration,
// capture, analysis, results — is the SAME flow; only the anchor differs.

/// Why a look may not be consultable, when saying so leaks nothing. The founder
/// gate stays a silent `available: false` with NO reason, exactly like the
/// booking endpoint — an unrecognised code decodes to `unknown` and is rendered
/// as the reason-agnostic refusal rather than crashing.
public enum ConsultLookUnavailableReason: String, Decodable, Sendable, Equatable {
    case lookServiceUnlinked = "LOOK_SERVICE_UNLINKED"
    case lookVerticalNotEnabled = "LOOK_VERTICAL_NOT_ENABLED"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public struct ConsultLookSession: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: ConsultSessionStatus
    public let lookPostId: String
    public let professionalId: String
    public let serviceCategoryId: String
    public let createdAt: String

    public init(
        id: String,
        status: ConsultSessionStatus,
        lookPostId: String,
        professionalId: String,
        serviceCategoryId: String,
        createdAt: String
    ) {
        self.id = id
        self.status = status
        self.lookPostId = lookPostId
        self.professionalId = professionalId
        self.serviceCategoryId = serviceCategoryId
        self.createdAt = createdAt
    }
}

struct ConsultLookSessionResponse: Decodable, Sendable {
    let consult: ConsultLookSession
}

/// GET /client/consult/look/availability — whether the consult door is open for
/// a LOOK. The server owns the whole decision (founder gate, look visibility,
/// service linkage, pilot vertical); the device never re-derives any of it and
/// shows an entry point only on an explicit `available: true`.
public struct ConsultLookAvailability: Decodable, Sendable {
    public let available: Bool
    public let reason: ConsultLookUnavailableReason?
    /// The caller's existing session for this look, when one exists.
    public let consult: ConsultLookSession?

    public init(
        available: Bool,
        reason: ConsultLookUnavailableReason?,
        consult: ConsultLookSession?
    ) {
        self.available = available
        self.reason = reason
        self.consult = consult
    }
}

struct ConsultLookAvailabilityResponse: Decodable, Sendable {
    let availability: ConsultLookAvailability
}

public enum ConsultAgreementKind: String, Codable, Sendable, CaseIterable {
    case sensitiveDataConsent = "SENSITIVE_DATA_CONSENT"
    case adult18PlusAttestation = "ADULT_18_PLUS_ATTESTATION"
}

public struct ConsultAgreementVersion: Decodable, Sendable, Identifiable {
    public let id: String
    public let kind: ConsultAgreementKind
    public let version: Int
    public let title: String
    public let body: String
    public let publishedAt: String
}

public struct ConsultAgreementAcceptance: Decodable, Sendable, Identifiable {
    public let id: String
    public let agreementVersionId: String
    public let version: Int
    public let acceptedAt: String
}

public struct ConsultAgreementRevocation: Decodable, Sendable {
    public let acceptanceId: String
    public let agreementVersionId: String
    public let version: Int
    public let acceptedAt: String
    public let revokedAt: String
    public let reason: String
}

public struct ConsultAgreementRequirement: Decodable, Sendable, Identifiable {
    public let kind: ConsultAgreementKind
    public let requiredVersion: ConsultAgreementVersion
    public let currentAcceptance: ConsultAgreementAcceptance?
    public let latestRevocation: ConsultAgreementRevocation?

    public var id: ConsultAgreementKind { kind }
    public var isAccepted: Bool { currentAcceptance != nil }
}

public struct ConsultAgreementState: Decodable, Sendable {
    public let consultId: String
    public let status: ConsultSessionStatus
    public let requirements: [ConsultAgreementRequirement]

    public var allCurrent: Bool {
        requirements.count == ConsultAgreementKind.allCases.count
            && Set(requirements.map(\.kind)) == Set(ConsultAgreementKind.allCases)
            && requirements.allSatisfy(\.isAccepted)
    }
}

struct ConsultAgreementStateResponse: Decodable, Sendable {
    let agreementState: ConsultAgreementState
}

struct ConsultAgreementAcceptResponse: Decodable, Sendable {
    let agreementState: ConsultAgreementState
    let replayed: Bool
}

/// REQUIRED / CONDITIONAL / SKIPPABLE, decoded leniently: a requirement this
/// build does not know reads as `.unknown` rather than failing the whole
/// intake response. (The server's current colour pack already carries a
/// CONDITIONAL question; shipped builds before this one could not decode it
/// at all.)
public enum ConsultIntakeRequirement: String, Decodable, Sendable {
    case required = "REQUIRED"
    case conditional = "CONDITIONAL"
    case skippable = "SKIPPABLE"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }

    /// Exactly the server's rule (`evaluateConsultIntakeProgress`): only
    /// REQUIRED blocks completion on its own. CONDITIONAL is required only
    /// when the pack's goal-direction rule says so, which the server decides
    /// and reports through `progress.canComplete`; SKIPPABLE is optional; a
    /// requirement this build does not know is left to the server as well.
    /// Labelling CONDITIONAL "Required" — as the previous build did — showed
    /// a client a demand the web never makes.
    public var mustAnswer: Bool { self == .required }
}

public struct ConsultIntakeOption: Decodable, Sendable, Identifiable, Equatable {
    public let value: String
    public let label: String
    public var id: String { value }
}

public struct ConsultIntakeQuestion: Decodable, Sendable, Identifiable {
    public let key: String
    public let label: String
    /// The server's own explanation of why a question is asked. Optional on the
    /// wire (most questions carry none) and rendered under the options, the
    /// same place the web wizard puts it.
    public let helpText: String?
    public let kind: String
    public let requirement: ConsultIntakeRequirement
    public let options: [ConsultIntakeOption]
    public var id: String { key }
}

public struct ConsultIntakeQuestionPack: Decodable, Sendable {
    public let id: String
    public let categorySlug: String
    public let version: Int
    public let schemaVersion: Int
    public let questions: [ConsultIntakeQuestion]
}

public struct ConsultIntakePrefillProvenance: Decodable, Sendable {
    public let source: String
    public let sourceId: String?
}

public struct ConsultIntakePrefillSuggestion: Decodable, Sendable {
    public let questionKey: String
    public let value: String
    public let provenance: [ConsultIntakePrefillProvenance]
}

public struct ConsultIntakePrefillSignal: Decodable, Sendable {
    public let source: String
    public let available: Bool
}

public struct ConsultIntakeRevision: Decodable, Sendable, Identifiable {
    public let id: String
    public let revision: Int
    public let packId: String
    public let packVersion: Int
    public let schemaVersion: Int
    public let complete: Bool
    public let answers: [String: String]
    public let createdAt: String
}

/// The server-owned answer to "can this intake be completed as saved?" —
/// the same field the web wizard gates its Continue on. Optional here only
/// so a fixture written before it decodes; the server always sends it.
public struct ConsultIntakeProgress: Decodable, Sendable {
    public let canComplete: Bool
    public let nextQuestionKey: String?
    public let blocker: String?
}

/// WHICH SERVICE this consult is about. The booking's service on a booking
/// anchor, the Look's primary service on a look anchor.
///
/// The flow is look-based, so before this it named the service NOWHERE and the
/// intake opened on "Have you had this kind of service before?" with nothing
/// for "this" to refer to (handoff B6). `name` is the plain-language name the
/// CLIENT is shown — the pro's own offering title where they set one;
/// `proFacingName` is the catalog name their menu uses.
///
/// Every field is nullable together: a Look whose linked service row was
/// deleted names nothing, and the screen says "your consult" rather than the
/// wrong service. Optional as a whole so a fixture written before it decodes.
public struct ConsultServiceIdentity: Decodable, Sendable {
    public let serviceId: String?
    public let name: String?
    public let proFacingName: String?
}

public struct ConsultIntakeState: Decodable, Sendable {
    public let consultId: String
    public let status: ConsultSessionStatus
    public let service: ConsultServiceIdentity?
    public let questionPack: ConsultIntakeQuestionPack
    public let progress: ConsultIntakeProgress?
    public let prefillSuggestions: [ConsultIntakePrefillSuggestion]
    public let prefillSignals: [ConsultIntakePrefillSignal]
    public let latestRevision: ConsultIntakeRevision?
}

struct ConsultIntakeStateResponse: Decodable, Sendable {
    let intake: ConsultIntakeState
}

struct ConsultIntakeSubmitResponse: Decodable, Sendable {
    let intake: ConsultIntakeState
    let replayed: Bool
}

// The inspiration step sits between intake and analysis: the client either
// attaches one reference photo of a LOOK (never of themselves) or explicitly
// continues without one, then answers the server-served questions about it.
// Analysis refuses to start until this review is complete (or skipped), which
// is why the flow cannot treat capture completion alone as "ready".

public enum ConsultInspirationQuestionKind: String, Decodable, Sendable, Equatable {
    case singleSelect = "SINGLE_SELECT"
    case multiSelect = "MULTI_SELECT"
    case text = "TEXT"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public struct ConsultInspirationQuestionOption: Decodable, Sendable, Identifiable, Equatable {
    public let value: String
    public let label: String
    public var id: String { value }
}

public struct ConsultInspirationQuestion: Decodable, Sendable, Identifiable, Equatable {
    public let key: String
    public let label: String
    public let helpText: String?
    public let kind: ConsultInspirationQuestionKind
    public let options: [ConsultInspirationQuestionOption]
    public let minSelections: Int
    public let maxSelections: Int
    public let allowText: Bool
    public var id: String { key }
}

public enum ConsultInspirationBlocker: String, Decodable, Sendable {
    case sourceDecisionRequired = "SOURCE_DECISION_REQUIRED"
    case questionsRemaining = "QUESTIONS_REMAINING"
    case atLeastThreeDetailsRequired = "AT_LEAST_THREE_DETAILS_REQUIRED"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public struct ConsultInspirationProgress: Decodable, Sendable {
    public let currentQuestion: ConsultInspirationQuestion?
    public let answeredQuestionCount: Int
    public let specificDetailCount: Int
    public let requiredSpecificDetailCount: Int
    public let canComplete: Bool
    public let blocker: ConsultInspirationBlocker?
}

public struct ConsultInspirationSourceState: Decodable, Sendable {
    public let inspirationId: String
    public let source: String
    public let lookPostId: String?
    /// Server-relative path (includes the `/api/v1` prefix) that answers with a
    /// short-lived signed read URL for an EXTERNAL_UPLOAD source.
    public let imageReadEndpoint: String
    public let imageAvailable: Bool
    public let useExpiresAt: String?
}

public struct ConsultInspirationState: Decodable, Sendable {
    public let consultId: String
    public let status: ConsultSessionStatus
    public let schemaVersion: Int
    public let introduction: String
    public let referenceNote: String
    public let reflectionPrompt: String
    public let source: ConsultInspirationSourceState?
    public let progress: ConsultInspirationProgress

    /// Done means the source decision was made AND every question is answered
    /// with enough specific detail — the analysis prerequisite this stage exists
    /// to satisfy.
    public var isComplete: Bool {
        progress.canComplete && progress.currentQuestion == nil
    }
}

struct ConsultInspirationStateResponse: Decodable, Sendable {
    let inspiration: ConsultInspirationState
}

struct ConsultInspirationMutationResponse: Decodable, Sendable {
    let inspiration: ConsultInspirationState
    let replayed: Bool
}

struct ConsultInspirationUpload: Decodable, Sendable {
    let inspirationId: String
    let schemaVersion: Int
    let contentType: String
    let maxBytes: Int
    let expiresAt: String
    let useExpiresAt: String
    let token: String
    let signedUrl: String?
}

struct ConsultInspirationIssueUploadResponse: Decodable, Sendable {
    let upload: ConsultInspirationUpload
    let replayed: Bool
}

public struct ConsultInspirationSignedRead: Decodable, Sendable {
    public let url: String
    public let expiresInSeconds: Double
}

/// Sentiment the client attaches to a free-text inspiration note. `NONE` exists
/// on the wire for "nothing else" reviews; the client only ever sends one of
/// these three alongside non-empty text.
public enum ConsultInspirationSentiment: String, Codable, Sendable, CaseIterable {
    case good = "GOOD"
    case bad = "BAD"
    case both = "BOTH"

    public var label: String {
        switch self {
        case .good: return "Something I like"
        case .bad: return "Something I’d avoid"
        case .both: return "A bit of both"
        }
    }
}

/// Idempotency keys for the inspiration upload's two writes (issue + attach).
public struct ConsultInspirationMutationKeys: Sendable, Equatable {
    public let issue: String
    public let attach: String

    public init(issue: String = UUID().uuidString, attach: String = UUID().uuidString) {
        self.issue = issue
        self.attach = attach
    }
}

/// Client-side mirror of the server's inspiration free-text rules
/// (`lib/consult/inspirationTextRules.ts`): the server enforces these on write;
/// mirroring them here blocks a doomed submit with a readable message instead
/// of an opaque 400. Change the rule on the server and this must move with it.
public enum ConsultInspirationTextRules {
    public static let maxCharacters = 240

    /// Inspiration notes describe the look in the reference photo, never the
    /// client's own traits — face/eye/skin/body language is refused durably
    /// (C10-W2 boundary).
    private static let unsupportedTraitLanguage = try! NSRegularExpression(
        pattern: "\\b(face|facial|eye|eyes|skin|undertone|complexion|identity|ethnic|ethnicity|race|health|medical|diagnosis|body|attractive|attractiveness)\\b",
        options: [.caseInsensitive]
    )

    public static func containsUnsupportedTraitLanguage(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return unsupportedTraitLanguage.firstMatch(in: text, range: range) != nil
    }
}

/// Selection rules for inspiration questions, mirrored from the web wizard and
/// the server validator (`NEUTRAL_VALUES` in `lib/consult/inspirationPack.ts`):
/// a neutral option ("None", "Not sure", …) never combines with any other
/// selection, and a written note excludes the "nothing-else" choice.
public enum ConsultInspirationAnswering {
    public static let neutralValues: Set<String> = [
        "none", "not-sure", "not-part-of-goal", "nothing-else",
    ]

    /// Apply one option tap to the current selection.
    public static func toggle(
        _ value: String,
        in current: [String],
        question: ConsultInspirationQuestion
    ) -> [String] {
        if question.kind == .singleSelect { return [value] }
        if current.contains(value) { return current.filter { $0 != value } }
        if neutralValues.contains(value) { return [value] }
        let withoutNeutrals = current.filter { !neutralValues.contains($0) }
        if withoutNeutrals.count >= question.maxSelections { return current }
        return withoutNeutrals + [value]
    }

    /// The values actually submitted: for the free-text question, a blank note
    /// with no selection means "nothing else" (server contract — the question
    /// is unanswerable otherwise).
    public static func effectiveValues(
        question: ConsultInspirationQuestion,
        selected: [String],
        trimmedText: String
    ) -> [String] {
        if question.allowText, trimmedText.isEmpty, selected.isEmpty {
            return ["nothing-else"]
        }
        return selected
    }
}

/// A capture slot's key, as the SERVER names it. Open by design (service-aware
/// consult, 2026-09-03): the pack served depends on the service family, and a
/// family added after this build ships must still render, upload and be
/// guided — so an unknown key decodes as itself rather than failing the whole
/// capture state. The known keys are static constants so call sites keep the
/// dot syntax they had when this was an enum.
public struct ConsultCaptureShotKey: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // The hair pack (v2): four hair views plus three face views.
    public static let hairBack = ConsultCaptureShotKey("hair_back")
    public static let hairLeft = ConsultCaptureShotKey("hair_left")
    public static let hairRight = ConsultCaptureShotKey("hair_right")
    public static let hairCrown = ConsultCaptureShotKey("hair_crown")
    public static let faceFront = ConsultCaptureShotKey("face_front")
    public static let faceSide = ConsultCaptureShotKey("face_side")
    public static let eyesCloseup = ConsultCaptureShotKey("eyes_closeup")
    // The area pack: the treatment area in context, then close.
    public static let areaWide = ConsultCaptureShotKey("area_wide")
    public static let areaCloseup = ConsultCaptureShotKey("area_closeup")

    /// The hair pack's seven keys, in the server's evidence order.
    public static let hairPack: [ConsultCaptureShotKey] = [
        .hairBack, .hairLeft, .hairRight, .hairCrown, .faceFront, .faceSide, .eyesCloseup,
    ]
}

public struct ConsultCaptureShot: Decodable, Sendable, Identifiable {
    public let key: ConsultCaptureShotKey
    public let title: String
    public let instruction: String
    public let requirement: String
    public var id: ConsultCaptureShotKey { key }
}

public struct ConsultCaptureShotPack: Decodable, Sendable {
    public let id: String
    public let categorySlug: String
    public let version: Int
    public let schemaVersion: Int
    public let shots: [ConsultCaptureShot]

    /// What the pack photographs, read off its shot KEYS — never its id, so a
    /// pack this build has not seen still describes itself. Mirrors the web's
    /// `describeConsultCapturePack` (lib/consult/captureCopy.ts).
    public var hairViewCount: Int { shots.filter { $0.key.rawValue.hasPrefix("hair_") }.count }
    public var areaViewCount: Int { shots.filter { $0.key.rawValue.hasPrefix("area_") }.count }
    public var faceViewCount: Int { shots.count - hairViewCount - areaViewCount }
}

public enum ConsultCaptureSlotStatus: String, Decodable, Sendable {
    case empty = "EMPTY"
    case uploaded = "UPLOADED"
    case accepted = "ACCEPTED"
    case rejected = "REJECTED"
    case expired = "EXPIRED"
    case purged = "PURGED"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

public struct ConsultCaptureSlot: Decodable, Sendable, Identifiable {
    public let shotKey: ConsultCaptureShotKey
    public let state: ConsultCaptureSlotStatus
    public let captureId: String?
    public let qualityReasonCode: String?
    public let retakeTip: String?
    public let rawExpiresAt: String?
    public let purgedAt: String?
    public var id: ConsultCaptureShotKey { shotKey }
}

/// The client's chart-copy choice (decision 2026-08-26): default-on but
/// visibly optional; changeable until analysis runs.
public struct ConsultChartCopyState: Decodable, Sendable, Equatable {
    public let optIn: Bool
    public let decidedAt: String?
}

public struct ConsultCaptureState: Decodable, Sendable {
    public let consultId: String
    public let status: ConsultSessionStatus
    public let shotPack: ConsultCaptureShotPack
    public let slots: [ConsultCaptureSlot]
    public let chartCopy: ConsultChartCopyState

    /// Every slot of the pack the server SERVED is accepted. The pack decides
    /// what "all" means — seven for hair, three for the face and area packs —
    /// not a list compiled into this build.
    public var hasAllAcceptedShots: Bool {
        let expected = Set(shotPack.shots.map(\.key))
        return !expected.isEmpty
            && slots.count == expected.count
            && Set(slots.filter { $0.state == .accepted }.map(\.shotKey)) == expected
    }
}

struct ConsultCaptureStateResponse: Decodable, Sendable {
    let capture: ConsultCaptureState
}

struct ConsultCaptureUpload: Decodable, Sendable {
    let uploadSessionId: String
    let shotKey: ConsultCaptureShotKey
    let shotPackVersion: Int
    let schemaVersion: Int
    let contentType: String
    let maxBytes: Int
    let expiresAt: String
    let rawExpiresAt: String
    let token: String
    let signedUrl: String?
}

struct ConsultCaptureIssueUploadResponse: Decodable, Sendable {
    let upload: ConsultCaptureUpload
    let replayed: Bool
}

struct ConsultCaptureAttachResponse: Decodable, Sendable {
    let capture: ConsultCaptureState
    let captureId: String
    let replayed: Bool
}

public struct ConsultCaptureQualityResult: Decodable, Sendable {
    public let captureId: String
    public let accepted: Bool
    public let reasonCode: String
    public let retakeTip: String?
    public let checkedAt: String
}

public struct ConsultCaptureQualityResponse: Decodable, Sendable {
    public let quality: ConsultCaptureQualityResult
    public let capture: ConsultCaptureState
    public let replayed: Bool
}

public struct ConsultConfidence: Decodable, Sendable, Equatable {
    public let min: Double
    public let max: Double
}

public struct ConsultObservation: Decodable, Sendable {
    public let value: String
    public let confidence: ConsultConfidence
    public let evidence: [String]
}

public struct ConsultAIObservations: Decodable, Sendable {
    /// Analysis schema v4: the two NAMED ends of the head.
    ///
    /// v3 sent one `currentLevel: { min, max }` and this screen rendered it
    /// "Level 4–5" — which a colourist reads as base-to-lightest, from a field
    /// that never said that was what it meant (the web's
    /// `lib/consult/hairLevel.ts` has the whole story). They are ordinary
    /// observations now, valued `LEVEL_1`…`LEVEL_10` or `UNKNOWN`, and a solid
    /// single-process legitimately reports the same value in both.
    public let baseLevel: ConsultObservation
    public let lightestLevel: ConsultObservation
    public let currentTone: ConsultObservation
    public let visibleCondition: ConsultObservation
    public let density: ConsultObservation
    public let texture: ConsultObservation
    public let goalSummary: String
    public let historySummary: String
    public let constraintsSummary: String
    public let maintenanceSummary: String
    public let appointmentContextSummary: String
}

public struct ConsultSafetyFlag: Decodable, Sendable, Identifiable {
    public let code: String
    public let summary: String
    public let discussWithProfessional: Bool
    public var id: String { code }
}

public struct ConsultServiceReference: Decodable, Sendable {
    public let type: String
    public let serviceId: String?
    public let serviceCategoryId: String
}

public struct ConsultClientIntakeItem: Decodable, Sendable, Identifiable {
    public let questionKey: String
    public let question: String
    public let answerCode: String
    public let answer: String
    public var id: String { questionKey }
}

public struct ConsultAchievabilityDirection: Decodable, Sendable {
    public let direction: String
    public let assessment: String
    public let context: String
    public let discussWithProfessional: Bool
}

public struct ConsultRecommendationDirection: Decodable, Sendable, Identifiable {
    public let title: String
    public let why: String
    public let direction: String
    public let reference: ConsultServiceReference
    public let discussWithProfessional: Bool
    public var id: String { "\(title):\(reference.serviceId ?? reference.serviceCategoryId)" }
}

public struct ConsultMeCardTeaser: Decodable, Sendable {
    public let locked: Bool
    public let tapped: Bool
}

/// Schema v2 (2026-08-26 full-analysis launch): the observed feature profile
/// behind the style directions. Every entry is an evidence-cited observation
/// with an honest UNKNOWN state.
public struct ConsultFeatureProfile: Decodable, Sendable {
    public let skinUndertone: ConsultObservation
    public let contrastLevel: ConsultObservation
    public let colorSeason: ConsultObservation
    public let faceProportion: ConsultObservation
    public let jawline: ConsultObservation
    public let foreheadProportion: ConsultObservation
    public let featureBalance: ConsultObservation
    public let eyeShape: ConsultObservation
    public let eyeSpacing: ConsultObservation
    public let browDensity: ConsultObservation
    public let browShape: ConsultObservation

    /// Stable render order + display labels for the profile grid.
    public var orderedEntries: [(label: String, observation: ConsultObservation)] {
        [
            ("Skin undertone", skinUndertone),
            ("Natural contrast", contrastLevel),
            ("Color season", colorSeason),
            ("Face proportion", faceProportion),
            ("Jawline", jawline),
            ("Forehead", foreheadProportion),
            ("Feature balance", featureBalance),
            ("Eye shape", eyeShape),
            ("Eye spacing", eyeSpacing),
            ("Brow density", browDensity),
            ("Brow shape", browShape),
        ]
    }
}

/// One professionally framed direction per style domain — discussion starting
/// points grounded in the feature profile, never promises.
public struct ConsultStyleDirection: Decodable, Sendable, Identifiable {
    public let domain: String
    public let title: String
    public let direction: String
    public let whyItFlatters: String
    public let confidence: ConsultConfidence
    public let evidence: [String]
    public let discussWithProfessional: Bool
    public var id: String { domain }

    public var domainLabel: String {
        switch domain {
        case "HAIR_COLOR_HARMONY": return "Hair color"
        case "CUT_AND_SHAPE": return "Cut & shape"
        case "BANGS": return "Bangs"
        case "BROWS": return "Brows"
        case "LASHES": return "Lashes"
        case "MAKEUP": return "Makeup"
        case "COLOR_PALETTE": return "Color palette"
        default: return ConsultResultPresentation.codeLabel(domain)
        }
    }
}

public struct ConsultClientResults: Decodable, Sendable {
    public let consultId: String
    // Book the Look, B2/B8 — EXACTLY ONE anchor is set. `bookingId` widened to
    // optional rather than being joined by a second results type, because a
    // look-anchored consult returns it as null and a non-optional String here
    // fails to decode the whole results payload. `lookPostId` is OPTIONAL on
    // the wire (absent, not null, on the booking-anchored path), which is what
    // `String?` decodes.
    public let bookingId: String?
    public let lookPostId: String?
    public let serviceCategoryId: String
    public let briefRevisionId: String
    public let briefRevision: Int
    public let analysisRevisionId: String
    public let analysisRevision: Int
    public let intakeRevisionId: String
    public let clientIntake: [ConsultClientIntakeItem]
    public let aiObservations: ConsultAIObservations
    public let profile: ConsultFeatureProfile
    public let styleDirections: [ConsultStyleDirection]
    public let safetyFlags: [ConsultSafetyFlag]
    public let achievabilityDirection: ConsultAchievabilityDirection
    public let recommendationDirections: [ConsultRecommendationDirection]
    /// The heading over the directions, from the serving tenant's brand
    /// copy. Optional on the wire (additive); the view falls back to the
    /// default heading when a server has not sent it.
    public let directionsTitle: String?
    public let meCardTeaser: ConsultMeCardTeaser
    public let createdAt: String

    public var hasFaithfulClientContract: Bool {
        (2...3).contains(recommendationDirections.count)
            && !styleDirections.isEmpty
            && meCardTeaser.locked
            && achievabilityDirection.discussWithProfessional
            && safetyFlags.allSatisfy(\.discussWithProfessional)
            && recommendationDirections.allSatisfy(\.discussWithProfessional)
            && styleDirections.allSatisfy(\.discussWithProfessional)
    }
}

struct ConsultClientResultsResponse: Decodable, Sendable {
    let results: ConsultClientResults
}

struct ConsultTeaserTapResponse: Decodable, Sendable {
    let teaser: ConsultMeCardTeaser
    let replayed: Bool
}

/// P4b: how far the background analysis has got. The waiting screen's copy is
/// keyed off this and nothing else.
public enum ConsultAnalysisRunStage: String, Decodable, Sendable {
    case queued = "QUEUED"
    case readingPhotos = "READING_PHOTOS"
    case understandingReference = "UNDERSTANDING_REFERENCE"
    case buildingPlan = "BUILDING_PLAN"
    case finalizing = "FINALIZING"
    case done = "DONE"
}

public enum ConsultAnalysisRunStatus: String, Decodable, Sendable {
    case queued = "QUEUED"
    case running = "RUNNING"
    case completed = "COMPLETED"
    case failed = "FAILED"

    /// The two states the client is still waiting through, and therefore the
    /// two the app should still be polling in.
    public var isLive: Bool { self == .queued || self == .running }
}

/// P4b: one background analysis run.
///
/// The analysis stopped being something a request does and became something a
/// job does, so the client needs a handle on the job. Everything here is a
/// lifecycle fact or a count — `failureCode` is a code this app maps to its own
/// copy, never a message to render.
public struct ConsultAnalysisRun: Decodable, Sendable {
    public let runId: String
    public let status: ConsultAnalysisRunStatus
    public let stage: ConsultAnalysisRunStage
    /// How many of her photos this run reads — the number in "reading your 4
    /// photos". A partial pack is supported, so it is not always the full pack.
    public let photoCount: Int
    public let attemptCount: Int
    public let maxAttempts: Int
    public let queuedAt: String
    public let startedAt: String?
    public let finishedAt: String?
    public let failureCode: String?
    /// Whether starting again would begin a fresh run. The SERVER decides this
    /// (it is true only for a FAILED run), so web and iOS cannot disagree about
    /// when the retry button is live.
    public let retryable: Bool
}

public struct ConsultAnalysisState: Decodable, Sendable {
    public let consultId: String
    public let status: ConsultSessionStatus
    public let schemaVersion: Int
    public let promptVersion: String
    // The client result is loaded from C7's immutable, pro-brief-derived route.
    // C8 needs only completion/provenance here, so the large provider payload is
    // deliberately skipped instead of becoming a second render source.
    public let result: ConsultAnalysisRevision?
    /// P4b: the most recent run, or nil when the analysis was never started.
    ///
    /// Optional in the decoder even though the server always sends it, because
    /// a shipped build must keep decoding a response from a server that has not
    /// deployed P4b yet — the same reason every other additive field here is
    /// optional. `nil` simply means "no run to show", which is the correct
    /// rendering on an old server.
    public let run: ConsultAnalysisRun?
}

public struct ConsultAnalysisRevision: Decodable, Sendable {
    public let revisionId: String
    public let revision: Int
    public let createdAt: String

    private enum CodingKeys: String, CodingKey { case revisionId, revision, createdAt }
}

struct ConsultAnalysisStateResponse: Decodable, Sendable {
    let analysis: ConsultAnalysisState
}

struct ConsultAnalysisStartResponse: Decodable, Sendable {
    let analysis: ConsultAnalysisState
    let replayed: Bool
}

public struct ConsultCaptureMutationKeys: Sendable, Equatable {
    public let issue: String
    public let attach: String
    public let quality: String

    public init(issue: String = UUID().uuidString, attach: String = UUID().uuidString,
                quality: String = UUID().uuidString) {
        self.issue = issue
        self.attach = attach
        self.quality = quality
    }
}

public enum ConsultClientFailure: Error, Sendable, Equatable {
    case hidden
    case unavailable
    case invalidState
    case invalidPhoto
    case photoTooLarge
    case contractMismatch
    case analysisPrerequisitesRequired
    case analysisCapturesRequired
    case analysisInspirationRequired

    public var message: String {
        switch self {
        case .hidden: return "This consult isn’t available."
        case .unavailable: return "The consult is unavailable right now. Please try again."
        case .invalidState: return "This consult changed. Return to your appointment and try again."
        case .invalidPhoto: return "That photo can’t be used. Choose a JPEG, PNG, or WebP image."
        case .photoTooLarge: return "That photo is too large. Choose an image under 5 MB."
        case .contractMismatch: return "We couldn’t safely show this consult. Please try again later."
        case .analysisPrerequisitesRequired:
            return "Your intake, inspiration, and photos need to be finished before the analysis can run."
        case .analysisCapturesRequired:
            return "At least one accepted photo is needed before the analysis can run."
        case .analysisInspirationRequired:
            return "Finish the inspiration step — add a photo and answer its questions, or continue without one — before the analysis can run."
        }
    }

    public static func stable(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        guard let api = error as? APIError else { return .unavailable }
        switch api {
        case let .server(status, _, code), let .serverDetails(status, _, code, _):
            if status == 404 { return .hidden }
            if code == "CONSULT_INVALID_STATE" || code == "CONSULT_PREREQUISITES_REQUIRED" {
                return .invalidState
            }
            if code == "CONSULT_CAPTURE_OBJECT_INVALID" { return .invalidPhoto }
            if code == "CONSULT_ANALYSIS_PREREQUISITES_REQUIRED" { return .analysisPrerequisitesRequired }
            if code == "CONSULT_ANALYSIS_CAPTURES_REQUIRED" { return .analysisCapturesRequired }
            if code == "CONSULT_ANALYSIS_INSPIRATION_REQUIRED" { return .analysisInspirationRequired }
            return .unavailable
        case .decoding: return .contractMismatch
        case .unauthorized, .invalidResponse, .transport: return .unavailable
        }
    }
}
