import Foundation

public enum ConsultFlowStage: Sendable, Equatable {
    case prerequisites
    case intake
    case capture
    case analysis
    case results
    case stopped
}

/// Small, content-agnostic lifecycle reducer. It validates that every response
/// remains anchored to the same server-owned consult/booking and that C7 result
/// provenance is complete before the UI can render any sensitive content.
public struct ConsultFlowMachine: Sendable, Equatable {
    private struct Revision: Sendable, Equatable {
        let id: String
        let number: Int
    }

    public let bookingId: String
    public private(set) var consultId: String?
    public private(set) var stage: ConsultFlowStage = .prerequisites
    private var serviceCategoryId: String?
    private var intakeRevisionId: String?
    private var analysisRevision: Revision?

    public init(bookingId: String) {
        self.bookingId = bookingId
    }

    public mutating func apply(session: ConsultSession) throws {
        guard session.bookingId == bookingId else { throw ConsultClientFailure.contractMismatch }
        try bind(consultId: session.id)
        serviceCategoryId = session.serviceCategoryId
        stage = Self.stage(for: session.status)
    }

    public mutating func apply(agreements: ConsultAgreementState) throws {
        try bind(consultId: agreements.consultId)
        if agreements.status == .consentRevoked || agreements.status == .cancelled {
            stage = .stopped
        } else if !agreements.allCurrent {
            stage = .prerequisites
        } else {
            let serverStage = Self.stage(for: agreements.status)
            stage = serverStage == .prerequisites ? .intake : serverStage
        }
    }

    public mutating func apply(intake: ConsultIntakeState) throws {
        try bind(consultId: intake.consultId)
        intakeRevisionId = intake.latestRevision?.id
        stage = Self.stage(for: intake.status)
    }

    public mutating func apply(capture: ConsultCaptureState) throws {
        try bind(consultId: capture.consultId)
        stage = Self.stage(for: capture.status)
        if capture.hasAllAcceptedShots, stage == .capture { stage = .analysis }
    }

    public mutating func apply(analysis: ConsultAnalysisState) throws {
        try bind(consultId: analysis.consultId)
        guard analysis.schemaVersion == ConsultService.analysisSchemaVersion,
              analysis.promptVersion == ConsultService.analysisPromptVersion else {
            throw ConsultClientFailure.contractMismatch
        }
        if let result = analysis.result {
            analysisRevision = Revision(id: result.revisionId, number: result.revision)
        }
        stage = Self.stage(for: analysis.status)
    }

    public mutating func apply(results: ConsultClientResults) throws {
        try bind(consultId: results.consultId)
        guard results.bookingId == bookingId,
              serviceCategoryId.map({ $0 == results.serviceCategoryId }) ?? true,
              !results.briefRevisionId.isEmpty,
              results.briefRevision > 0,
              !results.analysisRevisionId.isEmpty,
              results.analysisRevision > 0,
              !results.intakeRevisionId.isEmpty,
              intakeRevisionId.map({ $0 == results.intakeRevisionId }) ?? true,
              analysisRevision.map({
                  $0.id == results.analysisRevisionId && $0.number == results.analysisRevision
              }) ?? true,
              results.hasFaithfulClientContract else {
            throw ConsultClientFailure.contractMismatch
        }
        stage = .results
    }

    private mutating func bind(consultId candidate: String) throws {
        guard !candidate.isEmpty else { throw ConsultClientFailure.contractMismatch }
        if let consultId, consultId != candidate { throw ConsultClientFailure.contractMismatch }
        consultId = candidate
    }

    private static func stage(for status: ConsultSessionStatus) -> ConsultFlowStage {
        switch status {
        case .consentRequired: return .prerequisites
        case .intakeReady, .intakeInProgress: return .intake
        case .mediaReady: return .capture
        case .analysisPending, .analyzing: return .analysis
        case .completed: return .results
        case .consentRevoked, .cancelled, .unknown: return .stopped
        }
    }
}

public enum ConsultResultSection: String, Sendable, Equatable, CaseIterable {
    case clientWords
    case aiObservations
    case safety
    case achievability
    case directions
    case lockedMeCard
}

/// Render ordering is a contract, not incidental SwiftUI source order.
public enum ConsultResultPresentation {
    public static let sections: [ConsultResultSection] = [
        .clientWords,
        .aiObservations,
        .safety,
        .achievability,
        .directions,
        .lockedMeCard,
    ]

    public static func codeLabel(_ value: String) -> String {
        value.lowercased().split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    public static func confidence(_ value: ConsultConfidence) -> String {
        "\(Int((value.min * 100).rounded()))–\(Int((value.max * 100).rounded()))% confidence"
    }
}
