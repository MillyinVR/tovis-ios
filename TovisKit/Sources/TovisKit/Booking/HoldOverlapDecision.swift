import Foundation

/// The pro's live-hold decision, as it arrives on the wire.
///
/// B5 made a client's checkout an ANONYMOUS tile on the pro's calendar: the pro
/// sees the minutes are spoken for and nothing about who is holding them. This
/// is the popup shown when a pro tries to book over one of those, and the ONLY
/// thing it adds to that anonymity is whether the held client is new or
/// returning TO THIS PRO (Tori, 2026-08-28, explicitly and only that).
///
/// 🔴 Every stored property here is a string, an enum or a count. There is
/// deliberately no room for a name, an email, a phone, an avatar or a client id
/// — mirroring `lib/booking/holdOverlapPrompt.ts` field for field. Widening it
/// is a product decision, not a refactor.
public struct HeldSlotDecision: Sendable, Equatable, Identifiable {
    /// Whether the held client has booked with THIS pro before.
    ///
    /// `unknown` is a first-class value, not an error: a hold can have no
    /// client at all (`BookingHold.clientId` is nullable server-side), and
    /// inventing "new" for one would tell the pro something nobody checked.
    public enum Relationship: String, Sendable, Equatable {
        case new = "NEW"
        case returning = "RETURNING"
        case unknown = "UNKNOWN"
    }

    /// The hold's own id — an opaque key on the pro's own calendar.
    ///
    /// Doubles as `Identifiable.id` so `.sheet(item:)` can drive the popup: one
    /// live reservation, one sheet.
    public let holdId: String

    public var id: String { holdId }
    public let relationship: Relationship
    /// The service being held, as the pro's own catalog names it.
    public let serviceName: String
    public let startsAt: Date
    public let endsAt: Date
    /// When the reservation lapses — drives the same countdown the client sees.
    public let expiresAt: Date
    /// How many FURTHER live holds this one attempt would also book over.
    public let additionalHeldSlots: Int

    public init(
        holdId: String,
        relationship: Relationship,
        serviceName: String,
        startsAt: Date,
        endsAt: Date,
        expiresAt: Date,
        additionalHeldSlots: Int
    ) {
        self.holdId = holdId
        self.relationship = relationship
        self.serviceName = serviceName
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.expiresAt = expiresAt
        self.additionalHeldSlots = additionalHeldSlots
    }
}

/// Which action ran into the hold — only the wording differs.
public enum HoldOverlapPromptIntent: Sendable {
    case create
    case edit
}

/// The words the popup says. Mirrors `holdOverlapPromptCopy` on web so the two
/// platforms cannot start describing the same reservation differently.
///
/// 🔴 No function here takes anything but the relationship and the intent, so
/// no copy path can name anybody.
public enum HoldOverlapPromptCopy {
    public static let title = "Someone is checking out for this time"
    public static let countdownSuffix = "left to finish"
    public static let countdownLapsedNote =
        "Their checkout just ran out — this time is free again."
    public static let anonymityNote =
        "We only say new or returning while a checkout is in progress."
    public static let waitLabel = "Wait for them"

    /// "A returning client is booking" — the whole of what is said about them.
    public static func leadIn(_ relationship: HeldSlotDecision.Relationship) -> String {
        switch relationship {
        case .new: return "A new client is booking"
        case .returning: return "A returning client is booking"
        // Says only what is true. "A client" still tells the pro the time is
        // genuinely spoken for, which is the part that drives the decision.
        case .unknown: return "A client is booking"
        }
    }

    public static func proceedLabel(_ intent: HoldOverlapPromptIntent) -> String {
        switch intent {
        case .create: return "Book it anyway"
        case .edit: return "Move it here anyway"
        }
    }

    public static func additionalHeldSlotsNote(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        if count == 1 { return "One more client is checking out inside this time too." }
        return "\(count) more clients are checking out inside this time too."
    }

    /// The whole sentence the sheet shows: WHO (new or returning to this pro),
    /// WHAT, WHEN — in the booking location's zone.
    ///
    /// 🔴 Lives here, not as a private property of the SwiftUI view, so it can
    /// be ASSERTED. A view's private string is exactly the kind of thing that
    /// grows a client's name six months from now with no test to notice; a pure
    /// function whose only inputs are a `HeldSlotDecision` and a zone has
    /// nothing to grow one from.
    public static func summary(
        _ decision: HeldSlotDecision,
        timeZone: String?
    ) -> String {
        let when = Wire.dateTime(
            ISO8601DateFormatter.tovisWire.string(from: decision.startsAt),
            timeZone: timeZone
        )
        return "\(leadIn(decision.relationship)) \(decision.serviceName) for \(when)."
    }
}

extension ISO8601DateFormatter {
    /// The wire's own format, for the round-trip back through `Wire.dateTime`
    /// (which takes an ISO string, as every other caller has one).
    nonisolated(unsafe) static let tovisWire: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// The wire shape, decoded defensively.
///
/// Nothing is trusted as sent: an unknown relationship, an unparsable instant
/// or a missing service name yields nil and the caller falls back to its
/// ordinary error path. A popup that renders half a fact — "A client is
/// booking  for " — is worse than the plain refusal it replaced.
struct HeldSlotDecisionWire: Decodable {
    let holdId: String?
    let relationship: String?
    let serviceName: String?
    let startsAt: String?
    let endsAt: String?
    let expiresAt: String?
    let additionalHeldSlots: Int?

    private enum CodingKeys: String, CodingKey {
        case holdId, relationship, serviceName, startsAt, endsAt, expiresAt
        case additionalHeldSlots
    }

    /// Hand-written for the same reason `APIErrorBody`'s is: this rides inside
    /// an error body decoded with `try?`, so one odd field must not sink the
    /// `error`/`code` the user actually has to see.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        holdId = try? container.decodeIfPresent(String.self, forKey: .holdId)
        relationship = try? container.decodeIfPresent(String.self, forKey: .relationship)
        serviceName = try? container.decodeIfPresent(String.self, forKey: .serviceName)
        startsAt = try? container.decodeIfPresent(String.self, forKey: .startsAt)
        endsAt = try? container.decodeIfPresent(String.self, forKey: .endsAt)
        expiresAt = try? container.decodeIfPresent(String.self, forKey: .expiresAt)
        additionalHeldSlots = try? container.decodeIfPresent(
            Int.self, forKey: .additionalHeldSlots)
    }

    /// nil unless every required field is present and usable.
    func decoded() -> HeldSlotDecision? {
        guard
            let holdId = holdId?.trimmingCharacters(in: .whitespacesAndNewlines),
            !holdId.isEmpty,
            let rawRelationship = relationship,
            let relationship = HeldSlotDecision.Relationship(rawValue: rawRelationship),
            let serviceName = serviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !serviceName.isEmpty,
            let startsAt = startsAt.flatMap(Wire.date),
            let endsAt = endsAt.flatMap(Wire.date),
            let expiresAt = expiresAt.flatMap(Wire.date)
        else { return nil }

        return HeldSlotDecision(
            holdId: holdId,
            relationship: relationship,
            serviceName: serviceName,
            startsAt: startsAt,
            endsAt: endsAt,
            expiresAt: expiresAt,
            // A nicety, not a requirement: a server that omits it (or sends
            // nonsense) still gets the popup, just without the extra line.
            additionalHeldSlots: max(0, additionalHeldSlots ?? 0)
        )
    }
}

/// The error code the refusal-that-is-really-a-question comes back as.
public let holdOverlapDecisionCode = "HOLD_OVERLAP_NEEDS_CONFIRMATION"

extension APIError {
    /// The live-hold decision this failure is asking the pro to answer, if it
    /// is that failure at all.
    ///
    /// Requires `captureErrorDetails: true` on the call — the decision rides in
    /// `ServerErrorDetails`, like every other opted-in body field.
    public var holdOverlapDecision: HeldSlotDecision? {
        switch self {
        case let .serverDetails(_, _, code, details):
            guard code == holdOverlapDecisionCode else { return nil }
            return details.heldSlot
        case .server, .invalidResponse, .unauthorized, .decoding, .transport:
            return nil
        }
    }
}
