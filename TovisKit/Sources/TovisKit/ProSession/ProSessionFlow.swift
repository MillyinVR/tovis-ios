import Foundation

// Pure session-flow logic for the PRO live-session hub — the native counterpart
// of the web `lib/proSession/sessionFlow.ts` + `lib/proSession/closeoutChecklist.ts`.
// The server already resolves `effectiveSessionStep` in the session-state payload;
// the client uses these helpers to map that step → which screen to show and to
// build the persistent 4-step rail (Consult · Before · Service · Wrap-up). No
// network — kept pure + unit-tested so it lines up 1:1 with the web page.

/// The booking session lifecycle step (Prisma `SessionStep`). String-backed with
/// an `.unknown` fallback so a new server value never breaks decoding/mapping.
public enum SessionStep: String, Sendable, CaseIterable {
    case none = "NONE"
    case consultation = "CONSULTATION"
    case consultationPendingClient = "CONSULTATION_PENDING_CLIENT"
    case beforePhotos = "BEFORE_PHOTOS"
    case serviceInProgress = "SERVICE_IN_PROGRESS"
    case finishReview = "FINISH_REVIEW"
    case afterPhotos = "AFTER_PHOTOS"
    case done = "DONE"
    case unknown

    /// Parse a server step string (case-insensitive); nil/unknown → `.none`/`.unknown`.
    public init(serverValue: String?) {
        guard let raw = serverValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            self = .none
            return
        }
        self = SessionStep(rawValue: raw.uppercased()) ?? .unknown
    }
}

/// Which session-hub screen to render. Mirrors `ProSessionScreenKey` (the web
/// folds FINISH_REVIEW + AFTER_PHOTOS into one WRAP_UP surface).
public enum ProSessionScreenKey: Sendable, Equatable {
    case consultation
    case waitingOnClient
    case beforePhotos
    case serviceInProgress
    case wrapUp
    case done
}

/// One node of the 4-step rail.
public enum ProSessionRailKey: String, Sendable, Equatable {
    case consultation
    case beforePhotos
    case service
    case wrapUp
}

public enum ProSessionStepState: String, Sendable, Equatable {
    case idle, active, done
}

public struct ProSessionStepItem: Sendable, Equatable, Identifiable {
    public let key: ProSessionRailKey
    public let number: Int
    /// Short rail label (web `SESSION_RAIL_LABELS`).
    public let label: String
    public let state: ProSessionStepState

    public var id: String { key.rawValue }
}

public enum ProSessionFlow {
    // The four rail steps, in order (web `SESSION_STEPS` + `SESSION_RAIL_LABELS`).
    private static let railSteps: [(key: ProSessionRailKey, number: Int, label: String)] = [
        (.consultation, 1, "Consult"),
        (.beforePhotos, 2, "Before"),
        (.service, 3, "Service"),
        (.wrapUp, 4, "Wrap-up"),
    ]

    /// Port of `getSessionScreenKey({ effectiveStep })`.
    public static func screenKey(effectiveStep: SessionStep) -> ProSessionScreenKey {
        switch effectiveStep {
        case .none, .consultation, .unknown:
            return .consultation
        case .consultationPendingClient:
            return .waitingOnClient
        case .beforePhotos:
            return .beforePhotos
        case .serviceInProgress:
            return .serviceInProgress
        case .finishReview, .afterPhotos:
            // FINISH_REVIEW is a transient step on the way to AFTER_PHOTOS; both
            // resolve to the after-photos / wrap-up surface.
            return .wrapUp
        case .done:
            return .done
        }
    }

    /// Port of `buildSessionStepItems(effectiveStep)` — the persistent rail.
    public static func stepItems(effectiveStep: SessionStep) -> [ProSessionStepItem] {
        let progress = visualProgressNumber(for: effectiveStep)

        return railSteps.map { step in
            ProSessionStepItem(
                key: step.key,
                number: step.number,
                label: step.label,
                state: stepState(stepNumber: step.number, progress: progress),
            )
        }
    }

    // Port of `visualProgressNumberForStep`.
    private static func visualProgressNumber(for step: SessionStep) -> Int {
        switch step {
        case .done:
            return 5
        case .none, .consultation, .consultationPendingClient, .unknown:
            return 1
        case .beforePhotos:
            return 2
        case .serviceInProgress:
            return 3
        case .finishReview, .afterPhotos:
            return 4
        }
    }

    // Port of `stepStateForProgress`.
    private static func stepState(stepNumber: Int, progress: Int) -> ProSessionStepState {
        if progress == 5 { return .done }
        if stepNumber < progress { return .done }
        if stepNumber == progress { return .active }
        return .idle
    }
}
