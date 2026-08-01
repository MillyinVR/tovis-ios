import Foundation

/// K16's per-client booking requirements, as stored —
/// `GET/PUT/DELETE /api/v1/pro/clients/{id}/policy` (`ProClientPolicyDTO`).
///
/// Four switches a pro sets for ONE client, private to them: take a deposit,
/// take payment up front, require a saved card, and stop this client booking
/// themselves. They widen the pro's account-wide terms for this person; they
/// never narrow them.
///
/// 🔴 What arrives is the STORED row, never the RESOLVED policy. The server's
/// resolver zeroes `requireCardOnFile` while the save-card rail is dark — right
/// at booking time, wrong in a CONTROL, where a pro would open the form they
/// just set and find it blank. The rail flag travels separately as
/// `cardOnFileRailEnabled`, a CAPABILITY, so this surface disables that one row
/// instead of lying about its value ([[existing-control-can-still-be-lying]]).
///
/// 🔴 A whole `nil` policy is NOT four falses. It means the pro has set nothing
/// for this client, and the write route preserves that difference by DELETING
/// the row rather than storing an all-off one.
public struct ProClientPolicy: Decodable, Sendable, Equatable {
    /// Every prepay scope the server can store today. A value outside this set
    /// is a FUTURE scope this build cannot name — and `display` refuses the
    /// whole policy rather than showing prepay as off, because the pro would
    /// then be looking at a requirement they cannot see and would clear it on
    /// the very next save.
    public enum PrepayScope: String, Sendable, CaseIterable {
        case serviceOnly = "SERVICE_ONLY"
        case entireBooking = "ENTIRE_BOOKING"
    }

    /// DERIVED from `PrepayScope`, never hand-listed beside it (the K11/K13
    /// rule) — a third scope added to the enum is known here the moment it
    /// exists.
    public static let knownPrepayScopes: Set<String> = Set(PrepayScope.allCases.map(\.rawValue))

    /// Widen the pro's deposit scope to cover this client's bookings.
    public let requireDeposit: Bool?
    /// Per-client prepay requirement, unioned with the offering's (wider wins).
    /// Null means no prepay requirement — the scope column IS the switch.
    public let prepayScope: String?
    /// Client must have a saved card before a booking can be finalized. Enforced
    /// only while the rail is live; see `cardOnFileRailEnabled` on the response.
    public let requireCardOnFile: Bool?
    /// Client may not create a NEW appointment themselves. Does not refuse a
    /// reschedule or a waitlist-offer confirmation.
    public let blockSelfServeBooking: Bool?

    private enum CodingKeys: String, CodingKey {
        case requireDeposit, prepayScope, requireCardOnFile, blockSelfServeBooking
    }

    /// Non-throwing, like every other model on this wire: a malformed field must
    /// not fail the decode of the chart screen that carries it.
    ///
    /// ⚠️ Leniency here buys a READ, never a WRITE. `display` below is what any
    /// editing surface must go through, and it refuses anything partial.
    public init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        requireDeposit = (try? container?.decodeIfPresent(Bool.self, forKey: .requireDeposit)) ?? nil
        prepayScope = (try? container?.decodeIfPresent(String.self, forKey: .prepayScope)) ?? nil
        requireCardOnFile = (try? container?.decodeIfPresent(Bool.self, forKey: .requireCardOnFile)) ?? nil
        blockSelfServeBooking = (try? container?.decodeIfPresent(Bool.self, forKey: .blockSelfServeBooking)) ?? nil
    }

    public init(
        requireDeposit: Bool?,
        prepayScope: String?,
        requireCardOnFile: Bool?,
        blockSelfServeBooking: Bool?
    ) {
        self.requireDeposit = requireDeposit
        self.prepayScope = prepayScope
        self.requireCardOnFile = requireCardOnFile
        self.blockSelfServeBooking = blockSelfServeBooking
    }

    /// The policy a surface may render AND edit, or nil when this build cannot
    /// vouch for all of it.
    ///
    /// 🔴 All four switches must have decoded. This is stricter than the badges'
    /// `display` on purpose, and the reason is the WRITE: the save is a
    /// whole-object PUT, so a form built from a half-decoded policy would clear
    /// the fields it failed to read the moment the pro toggled any other one.
    /// A requirement the pro never turned off must not come off because a field
    /// arrived malformed. When this is nil the surface shows that it could not
    /// load — it does not show an empty form.
    public var display: Display? {
        guard let requireDeposit,
              let requireCardOnFile,
              let blockSelfServeBooking else { return nil }
        // Absent is a real, meaningful value here (no prepay requirement); only a
        // PRESENT-but-unknown scope is the refusal.
        var scope: PrepayScope?
        if let prepayScope {
            guard let known = PrepayScope(rawValue: prepayScope) else { return nil }
            scope = known
        }
        return Display(
            requireDeposit: requireDeposit,
            prepayScope: scope,
            requireCardOnFile: requireCardOnFile,
            blockSelfServeBooking: blockSelfServeBooking
        )
    }

    /// A validated, editable policy — non-optional fields only.
    public struct Display: Sendable, Equatable {
        public let requireDeposit: Bool
        public let prepayScope: PrepayScope?
        public let requireCardOnFile: Bool
        public let blockSelfServeBooking: Bool

        public init(
            requireDeposit: Bool,
            prepayScope: PrepayScope?,
            requireCardOnFile: Bool,
            blockSelfServeBooking: Bool
        ) {
            self.requireDeposit = requireDeposit
            self.prepayScope = prepayScope
            self.requireCardOnFile = requireCardOnFile
            self.blockSelfServeBooking = blockSelfServeBooking
        }

        /// Nothing is required of this client. The server stores no row in this
        /// state — a save in this shape DELETEs — so the surface reads it as
        /// "no requirements set" rather than "four switches that are off".
        public var isEmpty: Bool {
            !requireDeposit && prepayScope == nil && !requireCardOnFile && !blockSelfServeBooking
        }

        /// The all-off policy a client with no stored row edits from.
        public static let none = Display(
            requireDeposit: false,
            prepayScope: nil,
            requireCardOnFile: false,
            blockSelfServeBooking: false
        )
    }
}

/// The full body of `GET/PUT/DELETE /api/v1/pro/clients/{id}/policy`
/// (`ProClientPolicyResponseDTO`).
///
/// 🔴 Callers take the WHOLE response, never just `policy`. `cardOnFileRailEnabled`
/// is a sibling wire field, and unwrapping one field at the service boundary is
/// exactly how a sibling ends up with no reader (the K17-A lesson).
public struct ProClientPolicyResponse: Decodable, Sendable, Equatable {
    /// The stored policy, or nil when this pro has set nothing for this client.
    public let policy: ProClientPolicy?
    /// 🔴 Whether the save-card rail is live at all (`ENABLE_NO_SHOW_PROTECTION`).
    ///
    /// A capability, not a policy value. While this is false the write route
    /// 409s a card-on-file requirement, so the card-on-file CONTROL must be
    /// disabled — not merely allowed to fail
    /// ([[kill-switch-must-reach-the-control]]). It decodes fail-CLOSED: a
    /// missing or malformed value reads as false, because offering a switch the
    /// server will refuse is the worse of the two mistakes.
    public let cardOnFileRailEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case policy, cardOnFileRailEnabled
    }

    public init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        policy = (try? container?.decodeIfPresent(ProClientPolicy.self, forKey: .policy)) ?? nil
        cardOnFileRailEnabled =
            ((try? container?.decodeIfPresent(Bool.self, forKey: .cardOnFileRailEnabled)) ?? nil) ?? false
    }

    public init(policy: ProClientPolicy?, cardOnFileRailEnabled: Bool) {
        self.policy = policy
        self.cardOnFileRailEnabled = cardOnFileRailEnabled
    }
}

/// The body of a policy PUT. Every field is sent every time: the route reads the
/// whole object and stores what it is given, so a partial write is a silent
/// clear of whatever was left out.
struct ProClientPolicyRequest: Encodable {
    let requireDeposit: Bool
    let prepayScope: String?
    let requireCardOnFile: Bool
    let blockSelfServeBooking: Bool
}
