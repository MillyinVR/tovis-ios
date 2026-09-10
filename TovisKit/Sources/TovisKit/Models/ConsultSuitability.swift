import Foundation

/// Separate client and professional projections keep evidence out of client UI.
public struct ClientSuitability: Decodable, Sendable {
    public struct Tailoring: Decodable, Sendable {
        public let explanation: String
        public let needsConfirmation: Bool
    }
    public let analysisRevisionId: String
    public let clientRevisionId: String
    public let whatYouLoved: [String]
    public let tailoring: [Tailoring]
    public let proConfirmations: [String]
}

public struct SuitabilityEvidence: Decodable, Sendable {
    public let label: String
    public let value: String
    public let provenance: String
    public let revisionId: String
    public let confidence: ConsultConfidence?
    public let evidence: [String]?
}

public struct ProSuitability: Decodable, Sendable {
    public struct Tailoring: Decodable, Sendable {
        public let direction: String
        public let needsConfirmation: Bool
        public let sources: [SuitabilityEvidence]
    }
    public struct Confirmation: Decodable, Sendable {
        public let check: String
        public let sources: [SuitabilityEvidence]
    }
    public let analysisRevisionId: String
    public let clientRevisionId: String
    public let whatYouLoved: [String]
    public let tailoring: [Tailoring]
    public let proConfirmations: [Confirmation]
}

public enum ConsultSuitabilityCopy {
    public static let loved = "What you loved"
    public static let tailoring = "How we’d tailor it"
    public static let confirmations = "What your pro confirms"
    public static let clientNote = "Ideas to discuss with your pro, based on the details you shared."
    public static let proTitle = "Suitability guidance"
    public static let desiredChoices = "Desired choices"
    public static let professionalDirections = "Professional directions"
    public static let reviewRequired = "Professional review required"
    public static let clientConfirmation = "Your pro will check this in person."
    public static let observationUncertainty = "Photo-based observation; confirm in person."
    public static func provenance(_ value: String) -> String {
        switch value {
        case "CLIENT_REPORTED": "Client-reported"
        case "OBSERVED": "Observed"
        default: "Unspecified source"
        }
    }
    public static func confidence(_ value: ConsultConfidence) -> String {
        "Confidence: \(Int((value.min * 100).rounded()))–\(Int((value.max * 100).rounded()))%"
    }
}
