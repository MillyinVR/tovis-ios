import Foundation

public enum ConsultFlowStage: Sendable, Equatable {
    case prerequisites
    case intake
    case capture
    case analysis
    case results
    case stopped
}

/// What a consult hangs off. Book the Look (B2/B8) added the second case: the
/// SAME flow — agreements, intake, inspiration, capture, analysis, results —
/// reached from a look instead of from a booking. The machine's job is that
/// every response keeps naming the anchor the flow was opened on, so a
/// mixed-up id can never render one client's analysis inside another's booking.
public enum ConsultAnchor: Sendable, Equatable {
    case booking(String)
    case look(String)

    public var bookingId: String? {
        if case let .booking(id) = self { return id }
        return nil
    }

    public var lookPostId: String? {
        if case let .look(id) = self { return id }
        return nil
    }
}

/// Small, content-agnostic lifecycle reducer. It validates that every response
/// remains anchored to the same server-owned consult/anchor and that C7 result
/// provenance is complete before the UI can render any sensitive content.
public struct ConsultFlowMachine: Sendable, Equatable {
    private struct Revision: Sendable, Equatable {
        let id: String
        let number: Int
    }

    public let anchor: ConsultAnchor
    public private(set) var consultId: String?
    public private(set) var stage: ConsultFlowStage = .prerequisites
    private var serviceCategoryId: String?
    private var intakeRevisionId: String?
    private var analysisRevision: Revision?

    public init(anchor: ConsultAnchor) {
        self.anchor = anchor
    }

    public init(bookingId: String) {
        self.init(anchor: .booking(bookingId))
    }

    public mutating func apply(session: ConsultSession) throws {
        guard anchor == .booking(session.bookingId) else {
            throw ConsultClientFailure.contractMismatch
        }
        try bind(consultId: session.id)
        serviceCategoryId = session.serviceCategoryId
        stage = Self.stage(for: session.status)
    }

    /// Book the Look, B8 — the look-anchored twin. A separate entry point
    /// rather than a widened `apply(session:)` because the wire types are
    /// separate too: `ConsultLookSession` carries `lookPostId` where
    /// `ConsultSession` carries `bookingId`, and neither has the other's field
    /// to check.
    public mutating func apply(lookSession: ConsultLookSession) throws {
        guard anchor == .look(lookSession.lookPostId) else {
            throw ConsultClientFailure.contractMismatch
        }
        try bind(consultId: lookSession.id)
        serviceCategoryId = lookSession.serviceCategoryId
        stage = Self.stage(for: lookSession.status)
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

    public mutating func apply(inspiration: ConsultInspirationState) throws {
        try bind(consultId: inspiration.consultId)
        stage = Self.stage(for: inspiration.status)
    }

    // Server state is the truth for stage transitions: the server flips
    // MEDIA_READY → ANALYSIS_PENDING itself once captures and the inspiration
    // review are both satisfied, so an accepted-shots count alone must never
    // advance the stage locally (it once did, and dead-ended 7/7 packs whose
    // inspiration review was still open).
    public mutating func apply(capture: ConsultCaptureState) throws {
        try bind(consultId: capture.consultId)
        stage = Self.stage(for: capture.status)
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
        // 🔴 The results payload must still name the anchor this flow was
        // opened on. `bookingId` is null on a look-anchored consult and
        // `lookPostId` is null on a booking-anchored one, so the check is
        // against the anchor's OWN field — comparing an optional to an
        // optional would let two nils satisfy it and bind results to a flow
        // they do not belong to.
        guard Self.anchorMatches(anchor: anchor, results: results),
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

    private static func anchorMatches(
        anchor: ConsultAnchor,
        results: ConsultClientResults
    ) -> Bool {
        switch anchor {
        case let .booking(id): return results.bookingId == id
        case let .look(id): return results.lookPostId == id
        }
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
    case featureProfile
    case styleDirections
    case safety
    case achievability
    case directions
    case lockedMeCard
}

/// Render ordering is a contract, not incidental SwiftUI source order. The
/// full-analysis profile and per-domain style directions sit between the hair
/// observations and the always-visible safety section (schema v2).
public enum ConsultResultPresentation {
    public static let sections: [ConsultResultSection] = [
        .clientWords,
        .aiObservations,
        .featureProfile,
        .styleDirections,
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
