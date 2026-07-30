import Foundation

/// The NR / NNR / RR / RNR client-relationship mark of a booking — K5's wire
/// field, carried on the pro calendar's BOOKING events, the pro bookings-list
/// rows and the client chart's history rows.
///
/// The salon-book shorthand for "did this client ask for me, and have I seen
/// them before?". It is a per-booking SNAPSHOT taken at create time by web's ONE
/// helper (`lib/booking/relationshipLabel.ts`) — never derived from live
/// history, or a client's third booking would retroactively rewrite their first
/// booking's mark and the historical NR count would drift every time anyone
/// rebooked. The device renders `label`/`description` VERBATIM and derives
/// nothing.
///
/// Decoding is deliberately non-throwing, exactly like `ProPaymentBadge`: an
/// unknown future `kind`, a malformed value, or a missing subfield must never
/// fail the WHOLE calendar/list/chart decode. It degrades to `display == nil` —
/// the chip hides — mirroring web's kind-validated `parseRelationshipBadgeWire`.
public struct ProRelationshipBadge: Decodable, Sendable, Equatable {
    /// Every mark the web helper can emit today (decision D1 made RNR a real
    /// fourth cell: a returning client who arrived via discovery). A kind
    /// outside this list is a FUTURE state this build doesn't know — `display`
    /// hides it rather than rendering a mark whose meaning it can't vouch for.
    public static let knownKinds: Set<String> = [
        "NR", "NNR", "RR", "RNR", "UNKNOWN",
    ]

    public let kind: String?
    /// The bare mark the chip prints ("NR").
    public let label: String?
    /// Plain-words expansion ("New client · requested you"). Rides tooltips and
    /// the accessibility label — VoiceOver must never be handed bare letters.
    public let description: String?
    /// Web Badge tone vocabulary ("neutral" | "accent" | "info" | …), mapped to
    /// a brand color by the one `wireBadgeTone` table.
    public let tone: String?
    /// false only for UNKNOWN today — imported, pro-created and legacy rows.
    /// Those render NO chip anywhere: absence is the honest display for "nobody
    /// recorded this", and a wall of "Unknown" on imported history is noise. The
    /// decision lives in the web helper; absent on the wire defaults to true.
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

    /// The chip a surface may render, or nil to hide it: the kind must be one
    /// this build knows and the wire label must be non-blank (the mark is
    /// server-composed and never rebuilt on device, so without it there is
    /// nothing truthful to show).
    ///
    /// `description` falls back to the mark itself rather than to empty — an
    /// accessibility label is the one place this must not go silent.
    public var display: Display? {
        guard let kind, Self.knownKinds.contains(kind) else { return nil }
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let spelled = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Display(
            kind: kind,
            label: trimmed,
            description: (spelled?.isEmpty ?? true) ? trimmed : spelled!,
            tone: tone ?? "neutral",
            significant: significant ?? true
        )
    }

    /// A validated, renderable mark — non-optional fields only.
    public struct Display: Sendable, Equatable {
        public let kind: String
        public let label: String
        public let description: String
        public let tone: String
        public let significant: Bool
    }
}
