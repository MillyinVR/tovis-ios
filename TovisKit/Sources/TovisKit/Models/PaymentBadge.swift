import Foundation

/// The at-a-glance payment state of a booking — K1's wire field, carried on the
/// pro calendar's BOOKING events and the pro bookings-list rows.
///
/// The badge is derived by ONE web helper (`lib/booking/paymentBadge.ts`) and
/// consumed VERBATIM here: the device renders `label` and maps `tone` to a
/// brand color; it never recomputes the state from money fields (the one-helper
/// rule is the point — a payment label re-derived per surface drifts, and a
/// money label that drifts is the worst kind).
///
/// Decoding is deliberately non-throwing: an unknown future `kind`, a malformed
/// value, or a missing subfield must never fail the WHOLE calendar/list decode.
/// It degrades to `display == nil` — the chip is hidden, mirroring web's
/// kind-validated `parsePaymentBadgeWire`.
public struct ProPaymentBadge: Decodable, Sendable, Equatable {
    /// Every kind the web helper can emit today. A kind outside this list is a
    /// FUTURE state this build doesn't know — `display` hides it rather than
    /// rendering a label whose meaning it can't vouch for.
    public static let knownKinds: Set<String> = [
        "UNPAID", "DEPOSIT_DUE", "DEPOSIT_PAID", "PREPAID_IN_FULL",
        "PARTIALLY_PAID", "AWAITING_CONFIRMATION", "PAID", "WAIVED",
        "REFUNDED", "DISPUTED",
    ]

    public let kind: String?
    public let label: String?
    /// Web Badge tone vocabulary ("neutral" | "accent" | "danger" | "success" |
    /// "warn" | "info" | "pending"). The app maps it to a brand color in one
    /// place; an unrecognized tone falls back to muted there.
    public let tone: String?
    /// false only for UNPAID today: dense surfaces (the calendar tile) skip the
    /// badge — absence already reads as "nothing collected". The decision lives
    /// in the web helper; absent on the wire defaults to true (visible).
    public let significant: Bool?

    private enum CodingKeys: String, CodingKey {
        case kind, label, tone, significant
    }

    public init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container?.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        label = (try? container?.decodeIfPresent(String.self, forKey: .label)) ?? nil
        tone = (try? container?.decodeIfPresent(String.self, forKey: .tone)) ?? nil
        significant = (try? container?.decodeIfPresent(Bool.self, forKey: .significant)) ?? nil
    }

    public init(kind: String?, label: String?, tone: String?, significant: Bool?) {
        self.kind = kind
        self.label = label
        self.tone = tone
        self.significant = significant
    }

    /// The chip a surface may render, or nil to hide it: the kind must be one
    /// this build knows and the wire label must be non-blank (the label is
    /// server-composed — e.g. "Deposit paid $40.00" — and is never rebuilt on
    /// device, so without it there is nothing truthful to show).
    public var display: Display? {
        guard let kind, Self.knownKinds.contains(kind) else { return nil }
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return Display(
            kind: kind,
            label: trimmed,
            tone: tone ?? "neutral",
            significant: significant ?? true
        )
    }

    /// A validated, renderable badge — non-optional fields only.
    public struct Display: Sendable, Equatable {
        public let kind: String
        public let label: String
        public let tone: String
        public let significant: Bool
    }
}
