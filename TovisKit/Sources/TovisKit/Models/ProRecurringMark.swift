import Foundation

/// K19-C / K20 — "this appointment repeats", on the pro calendar's BOOKING
/// events and on a booking's detail.
///
/// 🔴 THE CHANNEL, and it is not the chip row. K7's budget spends fill+border on
/// status, the leading stripe on service, the corner glyph on client
/// confirmation and the warning triangle on conflict; the chip row already
/// carries location, relationship, payment and the K15 consent mark. Web put
/// this mark in the tile's TIME ROW beside the location chip, and the device
/// does the same — because the chip row is exactly where a tile runs out of
/// width first, and on a phone the last chip renders off-tile where only driving
/// the device would ever show it
/// ([[web-row-order-is-not-phone-priority-order]]).
///
/// It also belongs there on meaning, not just on space: "this repeats" is a fact
/// about the appointment's PLACEMENT, like when and where — not about its state,
/// its money or its risk.
///
/// 🔴 NO significance gate, unlike every badge next door. `ProPaymentBadge`,
/// `ProRelationshipBadge`, `ProClientConfirmation` and `ProConsentRequirement`
/// each carry one because each can be true-but-not-worth-saying. Recurrence is
/// not a warning that goes stale — an occurrence that has been and gone was
/// still part of a standing appointment. Web made the same call; a gate here
/// would be ceremony copied from a helper that needed it.
///
/// Decoding is non-throwing, exactly like those badges: a malformed value must
/// never fail the WHOLE calendar decode. It degrades to `display == nil` and the
/// mark simply hides.
public struct ProRecurringMark: Decodable, Sendable, Equatable {
    /// The series this occurrence belongs to. The load-bearing field: without it
    /// there is nothing to open, so a mark that lacks one is not a partial mark,
    /// it is not a mark.
    public let seriesId: String?
    /// 1-based, for humans. The backend's `seriesOccurrenceIndex` is 0-based and
    /// stays that way everywhere it is a KEY; this is the only place it becomes
    /// an ordinal, because "appointment 0 of 12" is not a thing anyone says.
    public let occurrenceNumber: Int?
    /// Plain words, server-composed. Rendered verbatim and never rebuilt here —
    /// the K6/K9 rule — because the mark itself is a shape and VoiceOver does
    /// not get shapes.
    public let description: String?

    private enum CodingKeys: String, CodingKey {
        case seriesId, occurrenceNumber, description
    }

    public init(from decoder: Decoder) {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        seriesId = (try? container?.decodeIfPresent(String.self, forKey: .seriesId)) ?? nil
        occurrenceNumber = (try? container?.decodeIfPresent(Int.self, forKey: .occurrenceNumber)) ?? nil
        description = (try? container?.decodeIfPresent(String.self, forKey: .description)) ?? nil
    }

    public init(seriesId: String?, occurrenceNumber: Int?, description: String?) {
        self.seriesId = seriesId
        self.occurrenceNumber = occurrenceNumber
        self.description = description
    }

    /// The mark a surface may render, or nil to render nothing.
    ///
    /// `description` falls back to a locally-composed phrase rather than to
    /// empty. That is a deliberate exception to "render server words verbatim":
    /// this string is the ACCESSIBILITY label, the one place the mark must not
    /// go silent, and the fallback states only what `seriesId` already proves.
    public var display: Display? {
        guard let seriesId = seriesId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !seriesId.isEmpty else { return nil }

        let number = (occurrenceNumber ?? 0) > 0 ? occurrenceNumber : nil
        let spelled = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let readable: String = {
            if let spelled, !spelled.isEmpty { return spelled }
            if let number { return "Repeating appointment \(number)" }
            return "Repeating appointment"
        }()

        return Display(
            seriesId: seriesId,
            occurrenceNumber: number,
            description: readable
        )
    }

    /// A validated, renderable mark — non-optional fields only.
    public struct Display: Sendable, Equatable {
        public let seriesId: String
        /// nil when the wire carried no usable ordinal; the mark still shows.
        public let occurrenceNumber: Int?
        public let description: String
    }
}
