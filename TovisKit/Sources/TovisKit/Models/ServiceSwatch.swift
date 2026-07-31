import Foundation

/// The pro's colour for a booking's SERVICE — K7/K8's wire field, carried on the
/// pro calendar's BOOKING events as `serviceSwatch`.
///
/// ── Why this is a channel, not just a colour ─────────────────────────────────
/// Four things want colour on one calendar tile — status, service, location and
/// (from K11) client confirmation — and four hues on one tile is unreadable. The
/// budget written down in web's `lib/calendar/eventColor.ts` gives each meaning
/// exactly one channel:
///
///   tile fill + border  → booking STATUS
///   3px leading stripe  → SERVICE swatch      (this type)
///   text chips          → location (K4) · relationship (K6) · payment (K2)
///   corner glyph        → client confirmation (K11, decision D3 — ✓ / ?)
///
/// 🔴 Anything new must CLAIM a channel or be refused.
///
/// ── Why the id is validated on arrival ───────────────────────────────────────
/// The swatch is stored as a plain `String?` column on
/// `ProfessionalServiceOffering` (K8), deliberately not an enum: the palette is a
/// BRAND token set a white-label tenant can change, so a stored id can outlive
/// the palette that defined it. Web narrows on every read
/// (`parseCalendarSwatch`); so does this. An id this build cannot paint must
/// degrade to "no colour" — the stripe keeps its status tone — never to a
/// half-painted tile the code believes it coloured.
///
/// Decoding is non-throwing, the `ProPaymentBadge` / `ProRelationshipBadge`
/// pattern: a value of the wrong TYPE (a number where a string belongs) is
/// swallowed here rather than failing the whole calendar decode. Absent — the
/// common case, and the only case until a pro picks a colour — never reaches
/// this initializer at all.
public struct ProServiceSwatch: Decodable, Sendable, Equatable {
    /// Every swatch id the palette defines, in picker order. Mirrors web's
    /// `CALENDAR_SWATCH_IDS` (`lib/calendar/eventColor.ts`), which mirrors
    /// `DEFAULT_CALENDAR_SWATCHES` in `lib/brand/defaults.ts`. Adding a 13th
    /// swatch means adding it here AND to `BrandColor.calendarSwatches` — the
    /// app-target test `CalendarSwatchPaletteTests` fails if the two disagree.
    public static let knownIds: [String] = [
        "01", "02", "03", "04", "05", "06",
        "07", "08", "09", "10", "11", "12",
    ]

    /// The validated id, or nil when the wire carried nothing this build can
    /// paint (an unknown id, a blank, a value of the wrong type).
    public let id: String?

    public init(from decoder: Decoder) {
        // `try?`, not `try`: a `serviceSwatch: 9` on the wire is a colour we
        // can't use, not a reason to lose the pro's whole day.
        let raw = try? decoder.singleValueContainer().decode(String.self)
        id = Self.parse(raw)
    }

    /// Build from a raw value (tests, previews). Validated exactly like the wire.
    public init(id: String?) {
        self.id = Self.parse(id)
    }

    /// Narrow an arbitrary string to a swatch id, or nil.
    public static func parse(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              knownIds.contains(trimmed)
        else { return nil }
        return trimmed
    }
}
