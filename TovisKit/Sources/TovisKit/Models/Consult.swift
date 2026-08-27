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

public enum ConsultIntakeRequirement: String, Decodable, Sendable {
    case required = "REQUIRED"
    case skippable = "SKIPPABLE"
}

public struct ConsultIntakeOption: Decodable, Sendable, Identifiable, Equatable {
    public let value: String
    public let label: String
    public var id: String { value }
}

public struct ConsultIntakeQuestion: Decodable, Sendable, Identifiable {
    public let key: String
    public let label: String
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

public struct ConsultIntakeState: Decodable, Sendable {
    public let consultId: String
    public let status: ConsultSessionStatus
    public let questionPack: ConsultIntakeQuestionPack
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
    nonisolated(unsafe) private static let unsupportedTraitLanguage = try! NSRegularExpression(
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

public enum ConsultCaptureShotKey: String, Codable, Sendable, CaseIterable {
    case hairBack = "hair_back"
    case hairLeft = "hair_left"
    case hairRight = "hair_right"
    case hairCrown = "hair_crown"
    // Pack v2 (2026-08-26 full-analysis launch): three face views join the
    // four hair views.
    case faceFront = "face_front"
    case faceSide = "face_side"
    case eyesCloseup = "eyes_closeup"
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

    public var hasAllAcceptedShots: Bool {
        let expected = Set(ConsultCaptureShotKey.allCases)
        return shotPack.shots.count == expected.count
            && slots.count == expected.count
            && Set(shotPack.shots.map(\.key)) == expected
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

public struct ConsultCurrentLevel: Decodable, Sendable {
    public let min: Int?
    public let max: Int?
    public let confidence: ConsultConfidence
    public let evidence: [String]
}

public struct ConsultAIObservations: Decodable, Sendable {
    public let currentLevel: ConsultCurrentLevel
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
    public let bookingId: String
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

public struct ConsultAnalysisState: Decodable, Sendable {
    public let consultId: String
    public let status: ConsultSessionStatus
    public let schemaVersion: Int
    public let promptVersion: String
    // The client result is loaded from C7's immutable, pro-brief-derived route.
    // C8 needs only completion/provenance here, so the large provider payload is
    // deliberately skipped instead of becoming a second render source.
    public let result: ConsultAnalysisRevision?
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
