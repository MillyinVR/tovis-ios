import Foundation

// Wire models for the PRO live-session footer state machine.
// Mirrors `tovis-app/lib/proSession/types.ts` (ProSessionPayload) and the route
// `app/api/v1/pro/session/route.ts`, which `jsonOk(payload)`-spreads the payload
// at the top level: { ok, mode, booking, eligibleBookings, targetStep, center }.
// String-backed enums carry an `.unknown` fallback so a new server value never
// fails decoding (same convention as `Role`).

/// The footer center button's high-level mode.
public enum ProSessionMode: String, Decodable, Sendable {
    case idle = "IDLE"
    case upcoming = "UPCOMING"
    case upcomingPicker = "UPCOMING_PICKER"
    case active = "ACTIVE"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProSessionMode(rawValue: raw) ?? .unknown
    }
}

/// What tapping the center button does. Ported from `UiSessionCenterAction`.
public enum ProSessionCenterAction: String, Decodable, Sendable {
    case none = "NONE"
    case start = "START"             // POST /session/start then navigate to href
    case navigate = "NAVIGATE"       // just go to href
    case finish = "FINISH"           // POST /session/finish then go to nextHref
    case captureBefore = "CAPTURE_BEFORE"
    case captureAfter = "CAPTURE_AFTER"
    case pickBooking = "PICK_BOOKING" // open the explicit booking picker
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ProSessionCenterAction(rawValue: raw) ?? .unknown
    }
}

/// A booking the session footer can act on (ACTIVE/UPCOMING or a picker row).
public struct ProSessionBooking: Decodable, Sendable, Identifiable {
    public let id: String
    public let serviceName: String?
    public let clientName: String?
    public let scheduledFor: String?
    public let sessionStep: String?
}

/// The center button's resolved state.
public struct ProSessionCenter: Decodable, Sendable {
    public let label: String
    public let action: ProSessionCenterAction
    public let href: String?

    public init(label: String, action: ProSessionCenterAction, href: String?) {
        self.label = label
        self.action = action
        self.href = href
    }
}

/// `GET /api/v1/pro/session` — the full footer payload (envelope spread).
public struct ProSessionPayload: Decodable, Sendable {
    public let mode: ProSessionMode
    public let booking: ProSessionBooking?
    public let eligibleBookings: [ProSessionBooking]?
    public let targetStep: String?
    public let center: ProSessionCenter
}

/// `POST /session/{start,finish}` — the server hands back where to go next.
struct ProSessionActionResponse: Decodable, Sendable {
    let nextHref: String?
}

// MARK: - Per-booking session state

/// `GET /api/v1/pro/bookings/{id}/session/state` → { ok, state, stateHash }.
/// Mirrors `buildProSessionState` (lib/proSession/sessionState.ts). The authoritative
/// state for one booking's live session — drives the session hub screen.
struct ProSessionStateResponse: Decodable, Sendable {
    let state: ProSessionState
}

public struct ProSessionState: Decodable, Sendable {
    public let bookingId: String
    public let status: String?
    public let sessionStep: String?
    public let effectiveSessionStep: String?
    /// Whether the booking is finished/cancelled (no further session actions).
    public let terminal: Bool
    public let startedAt: String?
    public let finishedAt: String?
    public let consultation: ProSessionStateConsultation?
    public let checkout: ProSessionStateCheckout?
    public let aftercare: ProSessionStateAftercare?

    /// The booking session step the server resolved this state to.
    public var step: SessionStep {
        SessionStep(serverValue: effectiveSessionStep ?? sessionStep)
    }

    /// Which hub screen to show for this state.
    public var screenKey: ProSessionScreenKey {
        ProSessionFlow.screenKey(effectiveStep: step)
    }

    public var isConsultationApproved: Bool {
        consultation?.status?.uppercased() == "APPROVED"
    }
    public var isConsultationPending: Bool {
        consultation?.status?.uppercased() == "PENDING"
    }
    public var isConsultationRejected: Bool {
        consultation?.status?.uppercased() == "REJECTED"
    }
}

public struct ProSessionStateConsultation: Decodable, Sendable {
    public let status: String?
    public let approvedAt: String?
    public let rejectedAt: String?
    /// How/when the consultation was decided (remote secure link vs in-person).
    /// Present once a decision has been recorded (tovis-app PR #441).
    public let proof: ProSessionStateProof?
}

public struct ProSessionStateProof: Decodable, Sendable {
    /// "APPROVED" | "REJECTED".
    public let decision: String?
    /// "REMOTE_SECURE_LINK" | "IN_PERSON_PRO_DEVICE".
    public let method: String?
    public let actedAt: String?

    /// "Approved" / "Rejected" (web `labelForConsultationDecision`).
    public var decisionLabel: String {
        switch decision?.uppercased() {
        case "APPROVED": return "Approved"
        case "REJECTED": return "Rejected"
        default: return "Unknown"
        }
    }

    /// "Remote secure link" / "In-person on pro device" (web `labelForProofMethod`).
    public var methodLabel: String {
        switch method?.uppercased() {
        case "REMOTE_SECURE_LINK": return "Remote secure link"
        case "IN_PERSON_PRO_DEVICE": return "In-person on pro device"
        default: return "Unknown"
        }
    }
}

public struct ProSessionStateCheckout: Decodable, Sendable {
    public let status: String?
    public let selectedPaymentMethod: String?
    public let paymentCollectedAt: String?

    /// Checkout is closed once paid or waived (web `hasCheckoutClosed`).
    public var isClosed: Bool {
        let s = status?.uppercased()
        return s == "PAID" || s == "WAIVED"
    }
}

public struct ProSessionStateAftercare: Decodable, Sendable {
    public let draftSavedAt: String?
    public let sentToClientAt: String?
    public let version: Int?

    public var hasDraft: Bool { draftSavedAt != nil || sentToClientAt != nil }
    public var isSent: Bool { sentToClientAt != nil }
}
