import Foundation

/// Whether the CLIENT has said they're coming — K11's confirmation state, on
/// the pro calendar's BOOKING events, the pro bookings-list rows, the pro
/// booking detail, and the client's own booking (where it is also the cue to
/// offer the in-app answer).
///
/// 🔴 This is the OPPOSITE direction from `BookingStatus.PENDING`, which tracks
/// the PRO's acceptance. It is deliberately not a status value at all: web
/// derives it from three orthogonal `Booking` timestamps, because a client
/// failing to confirm must never free the slot (an AWAITING_CLIENT or DECLINED
/// booking still occupies its time until the pro acts — decision D5, never
/// auto-cancel). Nothing on device may infer a lifecycle change from it.
///
/// 🔴 The words are never the bare "Confirmed": B10 gave that to
/// `BookingStatus.ACCEPTED`, and `BookingStatusPresentation` prints it on the
/// same rows. Web's one helper (`lib/booking/clientConfirmation.ts`) composes
/// "Client confirmed" / "Awaiting client" server-side; the device renders
/// `label`/`description` VERBATIM and derives nothing.
///
/// Decoding is non-throwing, exactly like `ProPaymentBadge` /
/// `ProRelationshipBadge`: an unknown future `kind`, a malformed value or a
/// missing subfield must never fail the WHOLE calendar/list/detail decode. It
/// degrades to `display == nil` — the glyph or pill simply hides.
public struct ProClientConfirmation: Decodable, Sendable, Equatable {
    /// Every state web's helper can emit today (its `CLIENT_CONFIRMATION_STATES`
    /// union). A value outside this set is a FUTURE state this build doesn't
    /// know — `display` hides it rather than rendering an attendance claim it
    /// can't vouch for.
    ///
    /// Deliberately an enum rather than a bag of string literals sprinkled
    /// through the views: the glyph, the pill and the client's answer card all
    /// have to agree on what "confirmed" is spelled like, and three hand-typed
    /// copies of `"CLIENT_CONFIRMED"` are three chances to be wrong in a way no
    /// compiler catches.
    public enum State: String, Sendable, CaseIterable {
        case notRequested = "NOT_REQUESTED"
        case awaitingClient = "AWAITING_CLIENT"
        case clientConfirmed = "CLIENT_CONFIRMED"
        case declined = "DECLINED"
    }

    /// DERIVED from `State`, never hand-listed beside it — a fifth case added to
    /// the enum is known here the moment it exists, and the two can't drift.
    public static let knownKinds: Set<String> = Set(State.allCases.map(\.rawValue))

    public let kind: String?
    /// The short words a pill prints ("Client confirmed", "Awaiting client").
    public let label: String?
    /// Plain-words expansion ("Client confirmed this appointment"). Rides the
    /// accessibility label ALWAYS — the calendar tile renders this state as a
    /// bare SHAPE, and a shape read aloud is nothing (the K5/K9-A rule).
    public let description: String?
    /// Web Badge tone vocabulary ("pending" | "success" | "danger" | …), mapped
    /// to a brand colour by the one `wireBadgeTone` table.
    public let tone: String?
    /// false only for NOT_REQUESTED — a booking nobody asked about renders
    /// NOTHING anywhere. Web omits the whole field in that case, so this is
    /// belt-and-braces for a row that carries it explicitly; the decision lives
    /// in the web helper, and absent on the wire defaults to true.
    public let significant: Bool?

    private enum CodingKeys: String, CodingKey {
        case kind, label, description, tone, significant
    }

    public init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container?.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        label = (try? container?.decodeIfPresent(String.self, forKey: .label)) ?? nil
        description = (try? container?.decodeIfPresent(String.self, forKey: .description)) ?? nil
        tone = (try? container?.decodeIfPresent(String.self, forKey: .tone)) ?? nil
        significant = (try? container?.decodeIfPresent(Bool.self, forKey: .significant)) ?? nil
    }

    public init(kind: String?, label: String?, description: String?, tone: String?, significant: Bool?) {
        self.kind = kind
        self.label = label
        self.description = description
        self.tone = tone
        self.significant = significant
    }

    /// The state a surface may render, or nil to show nothing: the kind must be
    /// one this build knows and the wire label must be non-blank (the words are
    /// server-composed and never rebuilt on device, so without them there is
    /// nothing truthful to print).
    ///
    /// `description` falls back to the label rather than to empty — it is the
    /// accessibility string, the one place this must not go silent.
    public var display: Display? {
        guard let kind, let state = State(rawValue: kind) else { return nil }
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let spelled = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let readable = spelled.map { $0.isEmpty ? trimmed : $0 } ?? trimmed
        return Display(
            state: state,
            label: trimmed,
            description: readable,
            tone: tone ?? "neutral",
            significant: significant ?? true
        )
    }

    /// A validated, renderable state — non-optional fields only.
    public struct Display: Sendable, Equatable {
        public let state: State
        public let label: String
        public let description: String
        public let tone: String
        public let significant: Bool

        public var kind: String { state.rawValue }
    }
}

// MARK: - The client's in-app answer (POST /api/v1/client/bookings/{id}/confirmation)

/// What a signed-in client is answering. The same two answers the SMS link
/// carries — web shares one locked core between the token route and the authed
/// one, so an in-app answer produces byte-identical DB outcomes to the link.
public enum AppointmentConfirmationAnswer: String, Sendable {
    case confirm = "CONFIRM"
    case decline = "DECLINE"
}

struct AppointmentConfirmationRequest: Encodable, Sendable {
    let answer: String  // "CONFIRM" | "DECLINE"
}

/// `POST /api/v1/client/bookings/{id}/confirmation` → `{ ok, state, booking,
/// meta }`. `state` is the resulting `ClientConfirmationState`, re-read from the
/// row the write just stamped — the caller adopts it rather than assuming its
/// own answer landed, since the route can refuse (already started, cancelled)
/// after the tap.
public struct AppointmentConfirmationResult: Decodable, Sendable {
    public let state: String
    public let booking: AppointmentConfirmationBooking?

    /// The echoed state, when it is one this build knows. nil for a state a
    /// future server invented — a caller should then keep showing what it had
    /// rather than render a state it can't describe.
    public var resolvedState: ProClientConfirmation.State? {
        ProClientConfirmation.State(rawValue: state)
    }
}

public struct AppointmentConfirmationBooking: Decodable, Sendable, Identifiable {
    public let id: String
    public let status: String?
    public let scheduledFor: String?
}
